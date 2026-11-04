`timescale 1ns/1ps
//==========================================================================
// enh_v2.v —— project8 像素通路（★ 曲线表只存一份 + 每帧合成"工作曲线"）
//
//   Y'(pixel) = clamp( TM(bank, base) + coring(detail) )      （与 project6 完全一致）
//     detail = Y - base
//     coring : |detail| < 4 / <10 / <20 -> G = 128/192/224/256，dout = sign(detail)*((G*|d|)>>8)
//     color  : 加法补偿 dY = Y'-Y，并做"削顶余量限幅"（保色相）
//
//   【project8 改了什么，为什么】
//   基线（project6）为做"两档之间连续插值"，把曲线表存了**两份**
//   （tm_lut + tm_lut2，各 1536x8），因为一个像素要同时读旧档和新档两条曲线；
//   实测这两份表占掉约 170 个分布式 RAM（DRAM 210 -> 40 就是本版省下来的）。
//
//   但注意：bank / bank_prev / blend_w 是 enh_top 在**帧边界**锁存的，
//   一帧之内恒定不变。所以"像素级插值"与"帧级先把两条曲线按同一权重合成一条
//   256 项工作曲线、像素只读这一条"在数学上**逐位相同**：
//       work[x] = ( ROM[prev][x]*(255-w) + ROM[bank][x]*w ) >> 8
//
//   本版结构（关键：**一整块 RAM，一个读口**）：
//       tm_all[0:1535]   = 6 条预置曲线（bank0..bank5；bank5 = HE，运行时可写）
//       tm_all[1536:1791]= bank6 = **工作曲线**（每帧消隐期由 FSM 合成）
//   像素通路只读 bank6（地址 = {3'd6, base_in}），FSM 也在同一读口上分时取数：
//     · 一个读口 + 一个写口 = SIMPLE_DUAL_PORT -> 综合成 1 块 18K DRM（不再被复制成 2 份）
//     · 综合实测：两份表（约 170 DRAM）-> 1 块块 RAM，分布式 RAM 210 -> 40
//   查表延迟仍是 1 拍（同一拍给地址、下一拍数据到），与基线一致；流水仍是 3 级。
//
//   触发点用 enh_stats 的 hist_ready：它正好在"帧末 HE 表 256 项全部写完"之后拉高，
//   所以读到的 bank5 一定是本帧的新表，与基线时序（消隐期建表、本帧像素就用）一致。
//   复位后 FSM 会自动先合成一遍（取 bank0），保证上电即有有效曲线、不黑屏。
//==========================================================================
module enh_v2 #(
    parameter PRESET_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/gamma_presets.mem"
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [7:0]  y_in,
    input  wire [7:0]  base_in,
    input  wire [15:0] rgb_in,
    input  wire [2:0]  bank,
    input  wire [2:0]  bank_prev,           // 上一档（平滑过渡用）
    input  wire [7:0]  blend_w,             // 过渡权重 0..255（0=旧档, 255=新档）
    input  wire        curve_tick,          // ★project8：帧末脉冲（= enh_stats 的 hist_ready）→ 重建工作曲线
    input  wire signed [8:0] corr_r,        // v10 暗场绿色偏移校正（R 通道加性补偿）
    input  wire signed [8:0] corr_b,        // v10 暗场绿色偏移校正（B 通道加性补偿）
    input  wire        we,                  // HE 表写入（只写 bank5）
    input  wire [7:0]  waddr,
    input  wire [7:0]  wdata,
    output reg         de_out,
    output wire        rom_bad_o,           // 诊断：gamma 表到底读进去没有（本版恒 0）
    output reg  [15:0] rgb_out
`ifdef SIM_DEBUG_PORT
    ,
    input  wire [10:0] dbg_addr,
    output reg  [7:0]  dbg_data
`endif
);

    //==========================================================================
    // 曲线存储：唯一一块 RAM（6 条预置曲线 + 1 条工作曲线）
    //==========================================================================
    localparam [2:0] BANK_WORK = 3'd6;      // 工作曲线所在 bank

    reg [7:0] tm_all [0:1791];
    initial begin
        $readmemh(PRESET_FILE, tm_all);     // 只填 0..1535；bank6 由复位后的 FSM 合成
    end

    //------------------------------------------ ★ 删除了"ROM 缺失安全网"（与基线一致）
    //  实测：对 BRAM 做固定地址组合读恒为 0，那段"保护"会把曲线永久旁路，
    //  还把故障伪装成"一切正常"。宁可表真丢了表现为坏画面，也不要静默杀死功能。
    assign rom_bad_o = 1'b0;

    //==========================================================================
    // 每帧合成工作曲线（消隐期完成；不占有效像素、不增加帧延迟）
    //==========================================================================
    localparam [1:0] C_IDLE = 2'd0, C_RA = 2'd1, C_RB = 2'd2, C_WR = 2'd3;

    reg  [1:0]  cst;
    reg  [7:0]  cidx;
    reg  [2:0]  cb_prev, cb;
    reg  [7:0]  cw;
    reg         c_blend;
    reg         c_req;
    reg  [7:0]  qa;

    // 与基线一致：bank0 就是表里第 0 条真实曲线
    wire [2:0] cb_use = (cb == 3'd0) ? 3'd0 : cb;

    // 与基线**完全相同**的插值使能条件：
    //   blend_en = (bank != bank_prev) && (bank != 5) && (bank_prev != 5) && (blend_w < 255)
    //   （涉及 HE(5) 时表每帧重建，不插值、直接切）
    wire c_blend_w = (bank != bank_prev) && (bank != 3'd5) &&
                     (bank_prev != 3'd5) && (blend_w < 8'd255);

    //------------------------------------------ 唯一的读口：FSM 与像素通路分时复用
    //   像素在有效像素区，FSM 在消隐期 —— 两者不会同时发生（这也是"帧级合成"
    //   与"像素级插值"能共用一块 RAM 的前提）。
    wire        fsm_rd   = (cst == C_RA) || (cst == C_RB);
    wire [10:0] fsm_addr = (cst == C_RA) ? {cb_prev, cidx} : {cb_use, cidx};
    wire [10:0] rom_rd_addr = fsm_rd ? fsm_addr : {BANK_WORK, base_in};
    reg  [7:0]  rom_rd_data;

    //------------------------------------------ ★ RAM 推断模板（关键）
    //   整块表只能有**一个读口 + 一个写口**，而且必须写在这个"只做读写"的
    //   always 块里；写口把两路写（HE 表 / 工作曲线）先合成一路。
    //   踩过的坑（都实测过）：
    //     · 读口放到别的 always 块、或写成两个写语句 -> Pango 不推断成 RAM，
    //       改用寄存器+多路选择器实现：LUT 11422->12667、FF 12898->17022（净涨）。
    wire        fsm_wr   = (cst == C_WR);
    wire [7:0]  work_val = c_blend
                         ? ((({9'd0, qa} * (17'd255 - {9'd0, cw})) +
                              ({9'd0, rom_rd_data} * {9'd0, cw})) >> 8)
                         : rom_rd_data;          // 非插值档：工作曲线 = 当前档那条
    wire        wr_en    = we | fsm_wr;
    wire [10:0] wr_addr  = we ? {3'b101, waddr} : {BANK_WORK, cidx};
    wire [7:0]  wr_data  = we ? wdata : work_val;

    always @(posedge clk) begin
        if (wr_en) tm_all[wr_addr] <= wr_data;
        rom_rd_data <= tm_all[rom_rd_addr];
`ifdef SIM_DEBUG_PORT
        dbg_data <= tm_all[dbg_addr];
`endif
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst     <= C_RA;          // 复位后先自动合成一遍（取 bank0），保证上电即有有效曲线
            cidx    <= 8'd0;
            cb_prev <= 3'd0;
            cb      <= 3'd0;
            cw      <= 8'd0;
            c_blend <= 1'b0;
            c_req   <= 1'b0;
            qa      <= 8'd0;
        end else begin
            if (curve_tick) begin      // 帧末：锁存本帧生效的档位/权重，重新合成
                cb_prev <= bank_prev;
                cb      <= bank;
                cw      <= blend_w;
                c_blend <= c_blend_w;
                cidx    <= 8'd0;
                c_req   <= 1'b1;
            end
            case (cst)
            C_IDLE: if (c_req) begin
                        c_req <= 1'b0;
                        cst   <= C_RA;
                    end
            C_RA: begin                // 读口：本拍给出"旧档"地址
                        cst <= C_RB;   // 下一拍 rom_rd_data = ROM[cb_prev][cidx]
                    end
            C_RB: begin                // 本拍收到旧档数据，同时给出"新档"地址
                        qa  <= rom_rd_data;
                        cst <= C_WR;
                    end
            C_WR: begin
                        // 本拍：qa = ROM[prev][i]（旧档），rom_rd_data = ROM[bank][i]（新档）
                        // 写口在下面的 RAM 模板里由 fsm_wr/work_val/wr_addr 统一完成
                        // （算式与基线"逐像素插值"逐位相同：同一个先乘后加再右移 8）
                        if (cidx == 8'd255) cst <= C_IDLE;
                        else begin
                            cidx <= cidx + 8'd1;
                            cst  <= C_RA;
                        end
                    end
            default: cst <= C_IDLE;
            endcase
        end
    end

    //==========================================================================
    // 第 1 级：查表 / 核化分档
    //   rom_rd_data 就是本拍的查表结果（同一拍给地址、下一拍数据到 = 1 拍延迟），
    //   与基线的 tm_r 等价，所以**不再多一级寄存器**，流水级数与基线完全一致。
    //   ★ v9（与基线一致）：处处 <=1 的去噪型曲线，不放大噪声、不做锐化
    //     |d|<4   0.500 最细纹理保留一半
    //     |d|<10  0.750
    //     |d|<20  0.875
    //     else    1.000 真实边缘，完全保留
    //==========================================================================
    wire signed [9:0] detail = $signed({2'b00, y_in}) - $signed({2'b00, base_in});
    wire        [7:0] absd   = detail[9] ? (~detail[7:0] + 8'd1) : detail[7:0];
    wire        [8:0] gcor   = (absd < 8'd4)  ? 9'd128 :
                               (absd < 8'd10) ? 9'd192 :
                               (absd < 8'd20) ? 9'd224 : 9'd256;

    reg  [8:0]  gcor_r;
    reg  [7:0]  absd_r;
    reg         sign_r;
    reg  [15:0] rgb_r;
    reg  [7:0]  y_r;
    reg         de1;
    always @(posedge clk) begin
        gcor_r <= gcor;
        absd_r <= absd;
        sign_r <= detail[9];
        rgb_r  <= rgb_in;
        y_r    <= y_in;
        de1    <= de;
    end

    //==========================================================================
    // 第 2 级：dout 与 Y'
    //==========================================================================
    wire [16:0] prod = gcor_r * absd_r;                // <=256*255
    wire [7:0]  dmag = prod[15:8];                     // (G*|d|)>>8
    wire [8:0]  dout = sign_r ? (~{1'b0, dmag} + 9'd1) : {1'b0, dmag};
    wire [9:0]  y2s  = $signed({1'b0, rom_rd_data}) + $signed(dout);
    wire [7:0]  y2   = y2s[9] ? 8'd0 : (y2s > 10'd255 ? 8'd255 : y2s[7:0]);
    reg  [7:0]  y2_r;
    reg  [7:0]  yref_r;
    reg  [15:0] rgb_r2;
    reg         de2;
    always @(posedge clk) begin
        y2_r   <= y2;
        yref_r <= y_r;
        rgb_r2 <= rgb_r;
        de2    <= de1;
    end

    //==========================================================================
    // 第 3 级：加法补偿 + 削顶余量限幅（保色相，与基线一致）
    //   dY 加"余量限幅"：正方向最多加到 255-max(RGB)、负方向最多减到 min(RGB)，
    //   保证任何通道都不会顶到 255/0 -> 不会"R/B 顶 255、G 继续涨"而泛绿。
    //==========================================================================
    wire [7:0] r8 = {rgb_r2[15:11], 3'b000};
    wire [7:0] g8 = {rgb_r2[10:5],  2'b00};
    wire [7:0] b8 = {rgb_r2[4:0],   3'b000};
    wire [7:0] mx = (r8 > g8) ? ((r8 > b8) ? r8 : b8) : ((g8 > b8) ? g8 : b8);
    wire [7:0] mn = (r8 < g8) ? ((r8 < b8) ? r8 : b8) : ((g8 < b8) ? g8 : b8);
    wire signed [9:0] dY_raw = $signed({2'b00, y2_r}) - $signed({2'b00, yref_r});
    wire signed [9:0] head_p = $signed({1'b0, 8'd255 - mx});
    wire signed [9:0] head_n = $signed({1'b0, mn});
    wire signed [9:0] dY = (dY_raw > head_p) ? head_p : ((dY_raw < -head_n) ? -head_n : dY_raw);
    wire signed [10:0] rsum = $signed({3'b000, r8}) + dY;
    wire signed [10:0] gsum = $signed({3'b000, g8}) + dY;
    wire signed [10:0] bsum = $signed({3'b000, b8}) + dY;
    wire signed [11:0] rsum_c = ({1'b0, rsum[10] ? 8'd0 : (rsum > 11'sd255 ? 8'd255 : rsum[7:0])}) + corr_r;
    wire signed [11:0] bsum_c = ({1'b0, bsum[10] ? 8'd0 : (bsum > 11'sd255 ? 8'd255 : bsum[7:0])}) + corr_b;
    wire [7:0] rq = (rsum_c[11] || rsum_c > 12'sd255) ? (rsum_c[11] ? 8'd0 : 8'd255) : rsum_c[7:0];
    wire [7:0] gq = gsum[10] ? 8'd0 : (gsum > 11'sd255 ? 8'd255 : gsum[7:0]);
    wire [7:0] bq = (bsum_c[11] || bsum_c > 12'sd255) ? (bsum_c[11] ? 8'd0 : 8'd255) : bsum_c[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out  <= 1'b0;
            rgb_out <= 16'd0;
        end else begin
            de_out  <= de2;
            rgb_out <= {rq[7:3], gq[7:2], bq[7:3]};
        end
    end
endmodule
