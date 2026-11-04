`timescale 1ns/1ps
//======================================================================
// enh_stats.v —— 每帧亮度统计 + 直方图均衡表生成（高阶任务三 · 720p60 版）
//
//   逐像素统计（精确）： sum / pix_cnt / dark_cnt / bright_cnt
//   采样统计（每 4 个窗口像素 1 个）： hist[256]（块 RAM）
//
//   ★ 资源/时序取舍（本模块最关键的一点）：
//     像素率 74.25 MHz，块 RAM 是**同步读**（地址当拍进、数据下一拍出）。
//     想在单拍里做"读-改-写"必须再加同桶转发，容易写错（实测踩过）。
//     改成每 4 个窗口像素更新一次：ph=0 地址进 → 1 等数据 → 2 用 rdata+1 写回 → 3 空拍。
//     直方图只用来生成一条曲线，采样 1/4 对结果几乎无影响（N_eff = 窗口像素数/4）。
//     对照：`hist[y] <= hist[y] + 1` 的异步读写法，PDS 实测约 4096 FF + 1586 宽 mux LUT。
//
//   ★ 代码风格（PDS 强制）：**所有寄存器只在一个 always 块里赋值**。
//     PDS 对"同一变量出现在两个 always 块"直接报 Verilog-4086（ModelSim 会放过去），
//     所以这里把采样流水、统计累加、帧末走表全部合到一个 always 块。
//
//   帧末：走 256 个桶算 CDF（顺便求 p10/p90），生成 HE 表：
//         raw = (cdf * 1814) >> 20        （≈ (cdf*255)/N_eff，0 乘法器）
//         lut = y + ((raw - y) * 154) >> 8（HE 强度 0.6，保持全动态范围）
//======================================================================
module enh_stats #(
    parameter integer DARK_TH   = 32,
    parameter integer BRIGHT_TH = 224,
    parameter integer WIN_X0    = 128,
    parameter integer WIN_X1    = 1152,
    parameter integer WIN_Y0    = 72,
    parameter integer WIN_Y1    = 648,
    parameter integer HE_S      = 20,
    parameter integer HE_K      = 1814,
    parameter integer HE_ALPHA  = 154
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [7:0]  luma,
    input  wire        frame_start,
    input  wire        win_disable,
    input  wire [11:0] split_x,
    output reg  [31:0] sum_o,
    output reg  [19:0] pix_cnt_o,
    output reg  [19:0] dark_cnt_o,
    output reg  [19:0] bright_cnt_o,
    output reg  [7:0]  p10_o,
    output reg  [7:0]  p90_o,
    output reg         hist_ready_o,
    output reg         busy_o,
    output reg         he_we,
    output reg  [7:0]  he_addr,
    output reg  [7:0]  he_data
`ifdef SIM_DEBUG_PORT
    ,
    input  wire [7:0]  dbg_hist_addr,
    output reg  [23:0] dbg_hist_data
`endif
);
    localparam integer HIST_W = 24;

    //-------------------------------------------------- 窗口判定
    wire win_x     = win_disable || ((x >= WIN_X0) && (x < WIN_X1));
    wire win_y     = win_disable || ((y >= WIN_Y0) && (y < WIN_Y1));
    wire win_split = (split_x == 12'd0) || (x >= split_x);
    wire in_win    = de && win_x && win_y && win_split;
    reg  freeze;                                   // 帧末冻结统计（必须在使用它的线网之前声明）
    wire cnt_en    = in_win && !freeze;
    wire smp_en    = cnt_en;
    //-------------------------------------------------- 状态
    reg [HIST_W-1:0] hist_mem [0:255];
    integer init_i;
    initial for (init_i = 0; init_i < 256; init_i = init_i + 1) hist_mem[init_i] = {HIST_W{1'b0}};

    reg  [HIST_W-1:0] rdata;
    reg  [7:0]        raddr;
    reg  [1:0]        ph;
    reg               we;
    reg  [7:0]        waddr;
    reg  [HIST_W-1:0] wdata;
    reg  [7:0]        walk_bin;
    reg               walk_read;
    reg [31:0] sum_r;
    reg [19:0] pix_r, dark_r, bright_r;

    localparam [2:0] S_IDLE = 3'd0, S_W0 = 3'd1, S_W1 = 3'd2, S_W2 = 3'd3, S_W3 = 3'd5, S_DONE = 3'd4;
    reg [2:0]  st;
    reg [7:0]  idx;
    reg [31:0] cdf;
    reg [7:0]  p10_r, p90_r;
    reg        got_p10, got_p90;
    reg [19:0] pix_smp;

    wire [7:0] raddr_now = walk_read ? walk_bin : raddr;

    // ★ HE 曲线要用"**包含**当前桶"的 CDF（cdf + rdata）：
    //   用加之前的 cdf 会整体少一个桶 -> 曲线非单调、与参考全不符（实测踩过）
    // ★ 并且必须真正用参数 HE_K（早先版本把 1814 写死在移位和里，
    //   换个 N_eff（例如小分辨率仿真）就静默算错 —— 这种"参数是摆设"的坑很隐蔽）
    // ★ 输出做**饱和**而不是截断：万一 cdf 超预期（例如漏清直方图导致累加），
    //   截断会让曲线"回绕"成非单调 -> 画面上就是饱和度爆炸的乱色；
    //   饱和只会让曲线变陡，不会乱。
    //
    // ★★ 走表做**两级流水**（这也是时序考虑）：
    //    第 1 级：算 cdf_next、乘 HE_K、饱和 -> 把 he_raw 与桶号寄存下来；
    //    第 2 级：用**寄存器输入**算强度混合并写表。
    //    不这么做的话，"32bit 乘法 + 饱和 + 16bit 有符号乘法 + 移位"全挤在一拍里，
    //    整机 PNR 实测会在 pix_clk 域差 0.059ns（1 个端点）—— 消隐期有的是拍数，
    //    多给 1 拍完全免费，换来时序干净收敛。
    wire [31:0] cdf_next = cdf + rdata;
    wire [43:0] cdf_k    = cdf_next * HE_K;      // 常量乘法，综合器自己优化
    wire [15:0] he_raw16 = cdf_k[HE_S + 15 : HE_S];
    wire [7:0]  he_raw   = (he_raw16 > 16'd255) ? 8'hFF : he_raw16[7:0];

    // 第 1 级寄存
    reg  [7:0]  idx_r;
    reg  [7:0]  raw_r;
    // 第 2 级：用寄存器输入做强度混合（组合深度很短）
    localparam signed [15:0] ALPHA_S = HE_ALPHA;
    wire signed [15:0] dif_s2   = $signed({8'd0, raw_r}) - $signed({8'd0, idx_r});
    wire signed [31:0] prod_s2  = dif_s2 * ALPHA_S;
    wire        [7:0]  he_blend = idx_r + prod_s2[15:8];

    //================================================== 唯一的一个时序块
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata <= {HIST_W{1'b0}}; raddr <= 8'd0; ph <= 2'd0;
            we <= 1'b0; waddr <= 8'd0; wdata <= {HIST_W{1'b0}};
            walk_bin <= 8'd0; walk_read <= 1'b0; freeze <= 1'b0;
            sum_r <= 32'd0; pix_r <= 20'd0; dark_r <= 20'd0; bright_r <= 20'd0;
            st <= S_IDLE; idx <= 8'd0; cdf <= 32'd0; idx_r <= 8'd0; raw_r <= 8'd0;
            p10_r <= 8'd0; p90_r <= 8'd0; got_p10 <= 1'b0; got_p90 <= 1'b0;
            pix_smp <= 20'd0;
            he_we <= 1'b0; he_addr <= 8'd0; he_data <= 8'd0;
            hist_ready_o <= 1'b0; busy_o <= 1'b0;
            sum_o <= 32'd0; pix_cnt_o <= 20'd0; dark_cnt_o <= 20'd0; bright_cnt_o <= 20'd0;
            p10_o <= 8'd0; p90_o <= 8'd0;
`ifdef SIM_DEBUG_PORT
            dbg_hist_data <= 24'd0;
`endif
        end else begin
            // ---------------- 默认 ----------------
            he_we        <= 1'b0;
            hist_ready_o <= 1'b0;
            we           <= 1'b0;
            rdata        <= hist_mem[raddr_now];
            if (we)
                hist_mem[waddr] <= wdata;
`ifdef SIM_DEBUG_PORT
            dbg_hist_data <= hist_mem[dbg_hist_addr];
`endif

            // ---------------- 帧末：走表建 HE 表 ----------------
            case (st)
            S_IDLE: begin
                walk_read <= 1'b0;
                if (frame_start) begin
                    sum_o        <= sum_r;
                    pix_cnt_o    <= pix_r;
                    dark_cnt_o   <= dark_r;
                    bright_cnt_o <= bright_r;
                    pix_smp      <= pix_r >> 2;
                    sum_r    <= 32'd0;
                    pix_r    <= 20'd0;
                    dark_r   <= 20'd0;
                    bright_r <= 20'd0;
                    freeze   <= 1'b1;
                    busy_o   <= 1'b1;
                    st       <= S_W0;
                    idx      <= 8'd0;
                    cdf      <= 32'd0;
                    got_p10  <= 1'b0;
                    got_p90  <= 1'b0;
                end
            end
            S_W0: begin
                walk_read <= 1'b1;
                walk_bin  <= idx;          // 把桶号交给 RAM
                st        <= S_W1;
            end
            S_W1: begin
                st <= S_W2;                // 等一拍：RAM 同步读，下一拍数据才有效
            end
            S_W2: begin
                // 此时 rdata 才是 mem[idx]（★ 只给两拍会拿到上一个桶 -> CDF 错位）
                // 第 1 级：算 he_raw 并寄存（把 32bit 乘法 + 饱和留在这一级）
                idx_r   <= idx;
                raw_r   <= he_raw;
                cdf     <= cdf + rdata;
                // ★★★ 顺手把这个桶清零（本帧统计完就不再需要它了）。
                //   曾经漏了这一步 —— 直方图跨帧累加：N 帧后 cdf 变成 N 倍，
                //   HE 定点乘法溢出回绕 -> 曲线非单调 -> 上板就是"彩虹乱色"。
                //   仿真只跑一帧时完全看不出来，所以务必保留"多帧回归测试"。
                we      <= 1'b1;
                waddr   <= idx;
                wdata   <= {HIST_W{1'b0}};
                if (!got_p10 && (((cdf + rdata) << 3) + ((cdf + rdata) << 1) >= pix_smp))
                    begin p10_r <= idx; got_p10 <= 1'b1; end
                if (!got_p90 && (((cdf + rdata) << 3) + ((cdf + rdata) << 1) >= (pix_smp * 9)))
                    begin p90_r <= idx; got_p90 <= 1'b1; end
                st <= S_W3;
            end
            S_W3: begin
                // 第 2 级：用寄存器输入做强度混合并写表（组合深度短，时序干净）
                he_we   <= 1'b1;
                he_addr <= idx_r;
                he_data <= he_blend;
                if (idx_r == 8'd255) begin
                    st <= S_DONE;
                end else begin
                    idx <= idx_r + 8'd1;
                    st  <= S_W0;
                end
            end
            S_DONE: begin
                p10_o        <= p10_r;
                p90_o        <= p90_r;
                hist_ready_o <= 1'b1;
                busy_o       <= 1'b0;
                walk_read    <= 1'b0;
                freeze       <= 1'b0;
                ph           <= 2'd0;
                we           <= 1'b0;
                st           <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase

            // ---------------- 帧内：逐像素统计 ----------------
            if (cnt_en && (st == S_IDLE)) begin
                sum_r <= sum_r + {24'd0, luma};
                pix_r <= pix_r + 20'd1;
                if (luma < DARK_TH[7:0])
                    dark_r <= dark_r + 20'd1;
                if (luma > BRIGHT_TH[7:0])
                    bright_r <= bright_r + 20'd1;
            end

            // ---------------- 帧内：直方图采样（每 4 个窗口像素 1 个）----------------
            if (smp_en && !walk_read) begin
                case (ph)
                2'd0: begin raddr <= luma; ph <= 2'd1; end
                2'd1: begin ph <= 2'd2; end
                2'd2: begin
                    we    <= 1'b1;
                    waddr <= raddr;
                    wdata <= rdata + {{(HIST_W-1){1'b0}}, 1'b1};
                    ph    <= 2'd3;
                end
                default: ph <= 2'd0;
                endcase
            end
        end
    end
endmodule
