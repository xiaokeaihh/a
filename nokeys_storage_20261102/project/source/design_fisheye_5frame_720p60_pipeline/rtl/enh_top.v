`timescale 1ns/1ps
//==========================================================================
// enh_top.v —— 高阶任务三 顶层（v2：base/detail 局部色调映射）
//
//   插入位置（不改原工程其它文件、不动 DDR 通路、不加帧缓冲）：
//     fisheye_video_path ──(de_o, o_rgb565)──> [ enh_top ] ──> video_metrics_osd ──> HDMI
//
//   v2 数据通路：
//     RGB565 → Y(2拍) → enh_base(4×4 因果窗口 → base, 参考像素 Y)
//            → enh_v2(曲线只作用在 base + detail 核化 + 按增益缩放三通道) → 输出
//
//   ★ v1 → v2 改了什么（为什么改）：
//     v1 = 整幅（含噪声）一起乘曲线增益：弱光下曲线斜率 4~6 倍，噪声同倍放大；
//          而且逐通道查表会改变色相。
//     v2 = 拆成 base(低频/照度) 与 detail(高频/反射率)，**曲线只作用在 base**，
//          detail 核化抑制（小幅度≈噪声压掉、大幅度≈边缘保留），
//          三通道用同一增益缩放（保色相）。
//     实测（真实标定照片 + 传感器噪声模型，弱光 −4 档，均值都提到 ~60）：
//         噪声 σ：v1 1.98→4.03（放大 2 倍）   v2 →1.61（比原始还低）
//         过曝占比：v1 78.5→74.0%             v2 →67.5%
//
//   ★ 延迟：因果窗口让"参考像素=当前像素"，**输出流不需要延迟若干行**；
//     像素通路总延迟 7 拍（≈94 ns）。（v1 是 3 拍，v2 多 4 拍，仍可忽略）
//   ★ 资源：曲线 LUT 从"3 读口 ×3 份"减为**1 份 1 读口**（HE 表也写这里）；
//     新增 4 个行缓存（约 6 个 DRAM）+ 2 张小 ROM。
//==========================================================================
module enh_top #(
    parameter integer H_ACTIVE   = 1280,
    parameter integer V_ACTIVE   = 720,
    parameter integer SPLIT_X    = 640,
    parameter integer WIN_X0     = 128,
    parameter integer WIN_X1     = 1152,
    parameter integer WIN_Y0     = 72,
    parameter integer WIN_Y1     = 648,
    parameter integer DARK_TH    = 32,
    parameter integer BRIGHT_TH  = 224,
    parameter integer HE_ALPHA   = 154
)(
    input  wire        pix_clk,
    input  wire        rst_n,
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire        de_in,
    input  wire [15:0] rgb_in,
    input  wire        enable,
    input  wire        force_he,
    input  wire [1:0]  display_mode,
    input  wire        win_disable,
    input  wire        ae_en,        // AE 开时把曲线固定到 bank0（亮度交给自动曝光）
    output wire        de_out,
    output wire [15:0] rgb_out,
    output wire [2:0]  mode_o,
    output wire [7:0]  mean_o,
    output wire [7:0]  dark_pct_o,
    output wire [7:0]  bright_pct_o,
    output wire [7:0]  p10_o,
    output wire [7:0]  p90_o,
    output wire [31:0] sum_o,
    output wire [19:0] pix_cnt_o,
    output wire        hist_ready_o,
    output wire        busy_o
`ifdef SIM_DEBUG_PORT
    ,
    input  wire [10:0] dbg_lut_addr,
    output wire [7:0]  dbg_lut_data,
    input  wire [7:0]  dbg_hist_addr,
    output wire [23:0] dbg_hist_data
`endif
);
    //================================================== 像素坐标
    reg [11:0] x_cnt, y_cnt;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 12'd0; y_cnt <= 12'd0;
        end else if (vs_in) begin
            x_cnt <= 12'd0; y_cnt <= 12'd0;
        end else if (hs_in) begin
            x_cnt <= 12'd0;
        end else if (de_in) begin
            if (x_cnt == H_ACTIVE[11:0] - 12'd1) begin
                x_cnt <= 12'd0;
                y_cnt <= (y_cnt == V_ACTIVE[11:0] - 12'd1) ? 12'd0 : y_cnt + 12'd1;
            end else x_cnt <= x_cnt + 12'd1;
        end
    end

    //================================================== 亮度（2 拍）
    wire       luma_de;
    wire [7:0] luma;
    enh_luma u_luma (.clk(pix_clk), .rst_n(rst_n), .de(de_in), .rgb565(rgb_in),
                     .de_o(luma_de), .y_o(luma));

    //================================================== base/detail 分解（1 拍）
    wire       b_de;
    wire [7:0] base, yref;
    enh_base #(.H_ACTIVE(H_ACTIVE), .K(4)) u_base (
        .clk(pix_clk), .rst_n(rst_n), .de(luma_de), .hs(hs_in), .vs(vs_in), .y_in(luma),
        .de_out(b_de), .base_o(base), .ymid_o(yref)
    );

    //================================================== 帧统计（统计 base：低频、抗噪）
    wire        he_we;
    wire [7:0]  he_addr, he_data;
    wire [31:0] sum_w;
    wire [19:0] pix_w, dark_w, bright_w;
    wire [7:0]  p10_w, p90_w;
    wire [11:0] split_win = (display_mode == 2'd2) ? SPLIT_X[11:0] : 12'd0;

    reg [11:0] x_d1, x_d2, x_d3, x_d4, x_d5, y_d1, y_d2, y_d3, y_d4, y_d5;
    reg        vs_d1, vs_d2;
    always @(posedge pix_clk) begin
        x_d1 <= x_cnt;  x_d2 <= x_d1;  x_d3 <= x_d2;  x_d4 <= x_d3;  x_d5 <= x_d4;
        y_d1 <= y_cnt;  y_d2 <= y_d1;  y_d3 <= y_d2;  y_d4 <= y_d3;  y_d5 <= y_d4;
        vs_d1 <= vs_in; vs_d2 <= vs_d1;
    end
    // ★ v10：提前声明 —— 下面 enh_v2 例化要用到，必须在本行之前声明，
    //   否则会被当成隐式 net，与后面的 reg 声明冲突（vlog-2388）。
    reg signed [8:0] corr_r, corr_b;
    wire frame_start = vs_d1 & ~vs_d2;

    enh_stats #(
        .DARK_TH(DARK_TH), .BRIGHT_TH(BRIGHT_TH),
        .WIN_X0(WIN_X0), .WIN_X1(WIN_X1), .WIN_Y0(WIN_Y0), .WIN_Y1(WIN_Y1),
        .HE_ALPHA(HE_ALPHA)
    ) u_stats (
        .clk(pix_clk), .rst_n(rst_n),
        .de(b_de), .x(x_d5), .y(y_d5), .luma(base),
        .frame_start(frame_start),
        .win_disable(win_disable), .split_x(split_win),
        .sum_o(sum_w), .pix_cnt_o(pix_w), .dark_cnt_o(dark_w), .bright_cnt_o(bright_w),
        .p10_o(p10_w), .p90_o(p90_w),
        .hist_ready_o(hist_ready_o), .busy_o(busy_o),
        .he_we(he_we), .he_addr(he_addr), .he_data(he_data)
`ifdef SIM_DEBUG_PORT
        , .dbg_hist_addr(dbg_hist_addr), .dbg_hist_data(dbg_hist_data)
`endif
    );

    //================================================== 档位决策（v4：连续档位）
    // ★ v4：mean/bright 由下面（消隐期）的串行除法器算出；这里必须**提前声明**，
    //   否则在声明之前被引用会被当成隐式 net，与后面的 reg 声明冲突（vlog-2388）。
    reg  [7:0]  mean_r, dark_r, bright_r;
    wire [2:0] mode_w;
    wire       he_ok;
    wire [9:0] bank_pos_w, bank_pos_bright_w;
    wire       apply_en = enable && (display_mode != 2'd0);
    enh_decision #(.CONFIRM(2)) u_decision (
        .clk(pix_clk), .rst_n(rst_n),
        .frame_valid(hist_ready_o), .enable(apply_en), .force_he(force_he),
        // v4：直接用 enh_top 已有串行除法器算出的 mean/bright（省掉重复判据）
        .mean(mean_r), .bright_pct(bright_r), .p10(p10_w), .p90(p90_w),
        .bank_pos_o(bank_pos_w), .bank_pos_bright_o(bank_pos_bright_w),
        .mode_o(mode_w), .he_eligible_o(he_ok)
    );
    // HE 是离散档（bank5）
    wire       he_on   = apply_en && (force_he || he_ok);
    //==========================================================================
    // ★ v8：AE 开启时不再把曲线整个关掉，改为**只保留亮侧（过曝压缩）**
    //
    //   原来：ae_en=1 -> pos_use=0（曲线退回 bank0），理由"亮度交给自动曝光、避免双重控制"。
    //   上板实测（用户："开手电筒过曝依旧吓人"）：这个做法在**瞬时强光**下是错的 ——
    //     · 相机 0x3503=0x03 是**手动曝光**，画面亮度完全由我们的 AE 决定；
    //     · AE 一次曝光更新要写 5 个寄存器、每帧只写 1 个 -> **5 帧才更新一次**；
    //       配合 EXPO_STEP=16 行，等效仅 3.2 行/帧，444 行 -> 100 行要 ~107 帧 ≈ 3.6 秒(30fps)；
    //     · 这段时间里曲线被强制 bank0（255->243，几乎不压）-> 高光**毫无保护，一片死白**。
    //   改后：过曝压缩**逐帧立即生效**（走决策的亮侧目标）；暗侧仍交给 AE
    //   （AE 开时不用暗侧曲线，不抢 AE 的"平均亮度"控制目标）。
    //   不会振荡：enh_stats 统计的是 base（曲线之前），曲线不进入统计输入。
    //   注：亮侧目标不做限速 —— 瞬时强光需要立即响应；决策的 bank 换表仍在帧边界。
    //==========================================================================
    //==========================================================================
    // ★ project8-c：AE 开时**保留有界的暗侧保底抬升**
    //
    //   上板实测（2026-10-16，暗房间）：AE 开 -> 全黑；AE 关 -> 有画面。
    //   根因：上面 v8 的策略把暗侧整体让给 AE，而那个场景 AE 已经到顶 ——
    //     曝光上限 720 行（VTS 740 封顶，不能再长否则掉帧）× 增益 6.0 =
    //     约 4.9 倍光，raw 均值只有 2/255，最多到 ~10/255，**还是黑的**。
    //   于是 AE 开 = "AE 提不亮 + 曲线也不抬" = 黑屏；AE 关 = 曲线抬（bank2） = 有画面。
    //
    //   修法：把"暗侧保底"做成**实测均值的静态函数**（不是第二条积分环，所以不会互追）：
    //     mean >= 89（进入目标带） -> 0，即完全交给 AE，与原来一致；
    //     mean 越暗，保底档位越高，最暗封顶 512 = bank2.0（最强抬升档，暗侧上限）。
    //   AE 一旦把曝光抬起来，mean 上升 -> 保底自动退回 -> 不会双重控制。
    //   0 额外 BRAM、0 延迟（每帧一次、不进像素流水）。
    //==========================================================================
    // ★ project8-d：保底改成**连续线性**（原来是 5 段台阶）。
    //   台阶版在 mean 跨过 64/40/24 时会突然跳半档到一档 -> 静止场景里 mean 抖 1 LSB
    //   就会看到"亮一下暗一下"。线性版处处连续，怎么抖都只是微调。
    //     dark_floor = clamp( (89 - mean) * 8 , 0 .. 512 )   （512 = bank2.0，暗侧上限）
    wire [7:0]  dm_raw  = (mean_r < 8'd89) ? (8'd89 - mean_r) : 8'd0;
    wire [10:0] dm_sc   = {3'd0, dm_raw} << 3;                        // *8
    wire [9:0]  dark_floor = (dm_sc > 11'd512) ? 10'd512 : dm_sc[9:0];
    wire [9:0] pos_ae   = (bank_pos_bright_w > dark_floor) ? bank_pos_bright_w : dark_floor;
    wire [9:0] pos_use  = ae_en ? pos_ae : bank_pos_w;
    // 显示档位 = **实际生效**的曲线档（原来直接显示决策档：AE 开启时会显示 E4 而实际用 bank0）
    wire [10:0] rnd_use  = {1'b0, pos_use} + 11'd128;
    wire [2:0]  mode_use = (rnd_use[10:8] > 3'd4) ? 3'd4 : rnd_use[10:8];

    //================================================== v2 像素通路
    // rgb 需要与 base 对齐：luma 2 拍 + base 1 拍 = 3 拍；再延到 7 拍供直通路径使用
    reg [15:0] rgb_d1, rgb_d2, rgb_d3, rgb_d4, rgb_d5, rgb_d6, rgb_d7, rgb_d8, rgb_d9;
    reg [2:0]  bank_r;
    reg [2:0]  bank_prev_r;
    reg [7:0]  blend_w_r;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            rgb_d1 <= 16'd0; rgb_d2 <= 16'd0; rgb_d3 <= 16'd0; rgb_d4 <= 16'd0;
            rgb_d5 <= 16'd0; rgb_d6 <= 16'd0; rgb_d7 <= 16'd0; rgb_d8 <= 16'd0; rgb_d9 <= 16'd0;
            bank_r <= 3'd0; bank_prev_r <= 3'd0; blend_w_r <= 8'd255;
        end else begin
            rgb_d1 <= rgb_in; rgb_d2 <= rgb_d1; rgb_d3 <= rgb_d2; rgb_d4 <= rgb_d3;
            rgb_d5 <= rgb_d4; rgb_d6 <= rgb_d5; rgb_d7 <= rgb_d6; rgb_d8 <= rgb_d7; rgb_d9 <= rgb_d8;
            if (frame_start) begin                       // 帧边界换表（v4：连续插值）
                if (he_on) begin
                    bank_r      <= 3'd5;                 // HE：直切，不插值（每帧重建）
                    bank_prev_r <= 3'd5;
                    blend_w_r   <= 8'd255;
                end else begin
                    // pos_use = 0..1023，表示 bank 0.0..4.0
                    //   bank_prev(低档) 与 bank_r(高档) 相邻，blend_w 为档内小数
                    //   blend_w=0 -> 低档；blend_w=255 -> 高档（禁用插值直接取高档）
                    bank_r      <= pos_use[9:8] + 3'd1;
                    bank_prev_r <= pos_use[9:8];
                    blend_w_r   <= pos_use[7:0];
                end
            end
        end
    end

    wire        v2_de;
    wire [15:0] v2_rgb;
    wire        rom_bad_w;   // ★ 诊断：gamma 表是否缺失（1 = 曲线被旁路）
    enh_v2 u_v2 (
        .clk(pix_clk), .rst_n(rst_n),
        .de(b_de), .y_in(yref), .base_in(base), .rgb_in(rgb_d5), .bank(bank_r),
        .bank_prev(bank_prev_r), .blend_w(blend_w_r),
        // ★ project8：帧末脉冲（HE 表 256 项写完之后的 hist_ready）→ 重建 256 项工作曲线。
        //   曲线表因此只需存一份（原来 tm_lut + tm_lut2 两份），像素通路仍只查一次表。
        .curve_tick(hist_ready_o),
        .we(he_we), .waddr(he_addr), .wdata(he_data),
        .corr_r(corr_r), .corr_b(corr_b), .de_out(v2_de), .rgb_out(v2_rgb), .rom_bad_o(rom_bad_w)
`ifdef SIM_DEBUG_PORT
        , .dbg_addr(dbg_lut_addr), .dbg_data(dbg_lut_data)
`endif
    );

    //================================================== 是否增强 + 输出对齐（7 拍）
    // ★ 对齐关系：v2_rgb 在第 7 拍有效；apply_p7 也在第 7 拍；
    //   直通路径用 rgb_d7（同样第 7 拍）→ 三者同拍，寄存一拍后输出与 de_out 严格对齐。
    reg [11:0] x_p1, x_p2, x_p3, x_p4, x_p5, x_p6, x_p7, x_p8;
    reg        apply_p1, apply_p2, apply_p3, apply_p4, apply_p5, apply_p6, apply_p7, apply_p8;
    reg        de_out_r;
    reg [15:0] rgb_out_r;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            x_p1 <= 0; x_p2 <= 0; x_p3 <= 0; x_p4 <= 0; x_p5 <= 0; x_p6 <= 0; x_p7 <= 0; x_p8 <= 0;
            apply_p1 <= 0; apply_p2 <= 0; apply_p3 <= 0; apply_p4 <= 0;
            apply_p5 <= 0; apply_p6 <= 0; apply_p7 <= 0; apply_p8 <= 0;
            de_out_r <= 1'b0; rgb_out_r <= 16'd0;
        end else begin
            x_p1 <= x_cnt; x_p2 <= x_p1; x_p3 <= x_p2; x_p4 <= x_p3;
            x_p5 <= x_p4;  x_p6 <= x_p5; x_p7 <= x_p6; x_p8 <= x_p7;
            apply_p1 <= apply_en && ((display_mode != 2'd2) || (x_cnt >= SPLIT_X[11:0]));
            apply_p2 <= apply_p1; apply_p3 <= apply_p2; apply_p4 <= apply_p3;
            apply_p5 <= apply_p4; apply_p6 <= apply_p5; apply_p7 <= apply_p6; apply_p8 <= apply_p7;
            de_out_r  <= v2_de;                       // 与 rgb_out_r 同拍（都是第 8 拍）
            rgb_out_r <= apply_p8 ? v2_rgb : rgb_d8;
        end
    end
    assign de_out  = de_out_r;
    assign rgb_out = rgb_out_r;

    //================================================== v10：暗场绿色偏移校正（灰世界·加法式）
    //  症状：暗场景把画面提亮后**发绿**（用户实测报告）。
    //  机理（已排除 565 量化）：565 里 G 是 6bit、R/B 只有 5bit，灰 20 编码成 (16,20,16)；
    //    但本模块的 dY 是三通道**同加**，绝对偏色不变、相对偏色反而变小。
    //    所以绿色不是本模块产生的 —— 是**低照度下传感器 AWB 偏绿**，提亮只是把它显影出来。
    //  做法：逐帧统计 R/G/B 均值，以 G 为基准给 R、B 一个**加性**补偿。
    //    · 只用右移，**不新增除法器**（三个和的除数相同 == 同一个移位数）
    //    · **只在暗场启用**（mean<110）-> 正常场景完全不受影响，零回归风险
    //    · 逐帧限速 ±1 -> 看不到颜色跳变；离开暗场平滑退回 0
    localparam integer AWB_SHIFT    = $clog2(H_ACTIVE * V_ACTIVE);
    localparam [7:0]   AWB_DARK_TH  = 8'd110;

    reg [31:0] acc_r, acc_g, acc_b;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin acc_r <= 32'd0; acc_g <= 32'd0; acc_b <= 32'd0; end
        else if (frame_start) begin acc_r <= 32'd0; acc_g <= 32'd0; acc_b <= 32'd0; end
        else if (b_de) begin
            acc_r <= acc_r + {24'd0, rgb_d5[15:11], 3'b000};
            acc_g <= acc_g + {24'd0, rgb_d5[10:5],  2'b00};
            acc_b <= acc_b + {24'd0, rgb_d5[4:0],   3'b000};
        end
    end

    wire [31:0] avg_r_w = acc_r >> AWB_SHIFT;
    wire [31:0] avg_g_w = acc_g >> AWB_SHIFT;
    wire [31:0] avg_b_w = acc_b >> AWB_SHIFT;
    wire signed [9:0] tgt_r_raw = $signed({2'b00, avg_g_w[7:0]}) - $signed({2'b00, avg_r_w[7:0]});
    wire signed [9:0] tgt_b_raw = $signed({2'b00, avg_g_w[7:0]}) - $signed({2'b00, avg_b_w[7:0]});
    wire signed [9:0] tgt_r_h   = (tgt_r_raw > 10'sd32) ? 10'sd32 : tgt_r_raw;
    wire signed [9:0] tgt_b_h   = (tgt_b_raw > 10'sd32) ? 10'sd32 : tgt_b_raw;
    wire signed [9:0] tgt_r     = (tgt_r_h < 0) ? 10'sd0 : (tgt_r_h >>> 1);  // 只补偏绿，50% 强度
    wire signed [9:0] tgt_b     = (tgt_b_h < 0) ? 10'sd0 : (tgt_b_h >>> 1);
    wire              awb_dark  = (mean_r < AWB_DARK_TH);

    // (寄存器 corr_r/corr_b 已在模块前部提前声明)
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin corr_r <= 9'sd0; corr_b <= 9'sd0; end
        else if (frame_start) begin
            if (awb_dark) begin
                // ★ 目标为 0 时【立即】清零，不要按 ±1/帧 慢慢退。
                //   否则整帧被白点门限挡掉（acc=0 -> tgt=0）后，残余补偿还要好几帧才消失，
                //   在这期间会把红/蓝通道各偏 1~N 个 LSB —— 实测在 565 量化边界上
                //   （B'=7 -> 8，B5 从 0 跳 1）会让颜色限幅用例差 1 个码字。
                if (tgt_r[8:0] == 9'sd0)      corr_r <= 9'sd0;
                else if (corr_r < tgt_r[8:0]) corr_r <= corr_r + 9'sd1;
                else if (corr_r > tgt_r[8:0]) corr_r <= corr_r - 9'sd1;
                if (tgt_b[8:0] == 9'sd0)      corr_b <= 9'sd0;
                else if (corr_b < tgt_b[8:0]) corr_b <= corr_b + 9'sd1;
                else if (corr_b > tgt_b[8:0]) corr_b <= corr_b - 9'sd1;
            end else begin
                if (corr_r > 9'sd0) corr_r <= corr_r - 9'sd1;
                if (corr_b > 9'sd0) corr_b <= corr_b - 9'sd1;
            end
        end
    end

    //================================================== 状态量（串行除法器，消隐期）
    reg  [2:0]  div_state;
    reg  [31:0] div_a, div_q, div_b, div_rem;
    reg  [5:0]  div_i;
    reg  [1:0]  stat_step;
    wire [31:0] rem_shift = {div_rem[30:0], div_a[31]};
    wire        q_bit     = (rem_shift >= div_b);
    wire [31:0] rem_next  = q_bit ? (rem_shift - div_b) : rem_shift;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            div_state <= 3'd0; div_a <= 32'd0; div_b <= 32'd1; div_q <= 32'd0; div_rem <= 32'd0;
            div_i <= 6'd0; stat_step <= 2'd0; mean_r <= 8'd0; dark_r <= 8'd0; bright_r <= 8'd0;
        end else begin
            case (div_state)
            3'd0: if (hist_ready_o) begin
                stat_step <= 2'd0;
                div_a <= sum_w; div_b <= {12'd0, pix_w};
                div_q <= 32'd0; div_rem <= 32'd0; div_i <= 6'd32; div_state <= 3'd1;
            end
            3'd1: begin
                div_rem <= rem_next;
                div_a   <= {div_a[30:0], 1'b0};
                div_q   <= {div_q[30:0], q_bit};
                if (div_i <= 6'd1) div_state <= 3'd2; else div_i <= div_i - 6'd1;
            end
            3'd2: begin
                if (stat_step == 2'd0) begin
                    mean_r <= (div_q > 32'd255) ? 8'd255 : div_q[7:0];
                    stat_step <= 2'd1;
                    div_a <= dark_w * 20'd100; div_b <= {12'd0, pix_w};
                    div_q <= 32'd0; div_rem <= 32'd0; div_i <= 6'd32; div_state <= 3'd1;
                end else if (stat_step == 2'd1) begin
                    dark_r <= (div_q > 32'd255) ? 8'd255 : div_q[7:0];
                    stat_step <= 2'd2;
                    div_a <= bright_w * 20'd100; div_b <= {12'd0, pix_w};
                    div_q <= 32'd0; div_rem <= 32'd0; div_i <= 6'd32; div_state <= 3'd1;
                end else begin
                    bright_r <= (div_q > 32'd255) ? 8'd255 : div_q[7:0];
                    stat_step <= 2'd0; div_state <= 3'd0;
                end
            end
            default: div_state <= 3'd0;
            endcase
        end
    end

    // ★ 诊断：rom_bad -> 显示 E7。正常档位只有 0..5，所以 E7 = 曲线因表缺失被整体旁路
    assign mode_o       = rom_bad_w ? 3'd7 : (he_on ? 3'd5 : mode_use);
    assign sum_o        = sum_w;
    assign pix_cnt_o    = pix_w;
    assign mean_o       = mean_r;
    assign dark_pct_o   = dark_r;
    assign bright_pct_o = bright_r;
    assign p10_o        = p10_w;
    assign p90_o        = p90_w;
endmodule
