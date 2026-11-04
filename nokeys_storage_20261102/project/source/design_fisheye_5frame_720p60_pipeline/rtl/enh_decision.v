`timescale 1ns/1ps
//======================================================================
// enh_decision.v —— 自适应档位决策（v4：★ 连续档位，取代 5 档硬切）
//
//   v3 及以前：算出一个离散 target(0..4)，二帧确认 + 迟滞，再靠 4 帧插值过渡。
//   v4：直接算出**连续**档位 bank_pos(0..1023 = bank 0.0 ~ 4.0)，并每帧限速逼近。
//       好处：① 曲线随场景连续变化，不再有"5 档台阶"；
//             ② 迟滞 + 二帧确认那一套可以去掉，由"限速"统一保证不跳变；
//             ③ 复用 enh_v2 里**本来就有**的两读口 + 插值通路，几乎不加资源。
//
//   档位按"严重度"单调排列（这是能插值的前提）：
//     t=0 常态 ｜ t=1 偏暗 ｜ t=2 很暗(夜间) ｜ t=3 偏亮 ｜ t=4 强过曝
//   ★ 曲线族在 Python 侧按同一 t 生成（tools/s62_v2b_gen.py 的 curve_t）。
//
//   映射（无除法，全用移位相加；输入 mean/bright 来自 enh_top 已有的串行除法器）：
//     暗侧：mean 89->t=0，46->t=1，26->t=2      d1=(89-mean)*6, d2=(46-mean)*13
//     亮侧：bright 8%->t=3，20%->t=4            (bright-8)*21 + 768
//     t = max(暗侧, 亮侧)                        （过曝优先，与 v3 一致）
//======================================================================
module enh_decision #(
    parameter integer CONFIRM = 2          // 兼容保留（连续版不再使用）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_valid,        // 帧末脉冲（stats 的 hist_ready）
    input  wire        enable,             // 0 = 强制直通
    input  wire        force_he,           // 1 = 长按强制 HE 模式
    input  wire [7:0]  mean,               // 画面均值 0..255
    input  wire [7:0]  bright_pct,         // 过曝占比 %
    input  wire [7:0]  p10, p90,
    output reg  [9:0]  bank_pos_o,         // ★ 连续档位 0..1023 = bank 0.0..4.0
    output wire [9:0]  bank_pos_bright_o,  // ★ 只含"亮侧(过曝压缩)"的档位；AE 开启时用它
    output reg  [2:0]  mode_o,             // 显示用整数档（四舍五入 0..4；HE 时 5）
    output reg         he_eligible_o
);
    localparam [7:0] M_NORM = 8'd89;       // 均值 >= 89 视为常态
    localparam [7:0] M_D1   = 8'd46;       // 46..89 -> t 0..1
    localparam [7:0] M_D2   = 8'd26;       // 26..46 -> t 1..2
    // ★ v9：门槛 4% -> 2%，斜率 21 -> 63。
    //
    //   【为什么不能再降】上板实测：普通房间 bright=2%，手电筒 bright=3%。
    //   两者只差 1 个百分点 —— 用"过曝面积"单一信号**分不开**它们。
    //   把门槛降到 0 会把普通房间也一起压暗（那正是用户抱怨的"比最开始差"）。
    //   所以取 2%：<=2% 不动（普通房间保持和 10/10 那版一致的观感），
    //   3%~6% 渐进压缩，>=6% 到最强档。手电筒(3%)得到 255->~204，
    //   靠近/变大(6%+)则到 255->177。
    localparam [7:0] B_ON   = 8'd2;        // >2% 才介入
    localparam [7:0] B_HI   = 8'd6;        // >=6% 到最强档
    localparam [9:0] STEP   = 10'd32;      // 每帧最多移动 32/1024（30fps 下约 1.1s 走完全程）
    // ★ project8-d（2026-10-17，治"静止画面亮暗抖动"）：
    //   原来 m_bs = bs*255，bs 只要 1（亮部 3%）就被饱和到 255 -> t_bright = 1023 = **bank4.0**
    //   （最强压暗，γ1.60，128->85）。于是"亮部从 2% 抖到 3%"就让曲线在 bank0 和 bank4 之间
    //   抽一次 —— 被 STEP=32/帧 拉成约 1 秒的亮暗脉动。这就是抖动的**主因**。
    //   两处修正：
    //     ① 斜率回到注释写的 63/64（*64）：3% -> t=832(bank3.25) -> 255 约 204，与文档一致；
    //        4% -> 3.5 档，6% 才到最强档，渐变而不是"一跳到底"。
    //     ② 亮侧加**滞回**：>=3% 才进入、<=1% 才退出，2%~3% 之间抖动不会反复开关。

    // 亮侧滞回锁存（帧末更新）
    reg b_on;
    // （声明位置见下方 always 块之前）
    wire [7:0] d1 = (mean < M_NORM) ? (M_NORM - mean) : 8'd0;     // 0..89
    wire [7:0] d2 = (mean < M_D1)   ? (M_D1   - mean) : 8'd0;     // 0..46
    // 滞回内的亮部超出量：进入后即使回到 2% 也保持最小一档，避免开关抖动
    wire [7:0] bs = b_on ? ((bright_pct > B_ON) ? (bright_pct - B_ON) : 8'd1) : 8'd0;

    // 暗侧：d1*6 = *4+*2 ；d2*13 = *8+*4+*1
    wire [15:0] m_d1   = ({8'd0, d1} << 2) + ({8'd0, d1} << 1);
    wire [15:0] d1c    = (m_d1 > 16'd256) ? 16'd256 : m_d1;
    wire [15:0] m_d2   = ({8'd0, d2} << 3) + ({8'd0, d2} << 2) + {8'd0, d2};
    wire [15:0] d2c    = (m_d2 > 16'd256) ? 16'd256 : m_d2;
    wire [15:0] t_dark = (d1c == 16'd256) ? (16'd256 + d2c) : d1c;      // 0..512

    // 亮侧：bs*64（★ project8-d：原写法实际是 *255，1% 就饱和）；基准 768 (= t3)
    wire [15:0] m_bs = {8'd0, bs} << 6;                                  // *64
    wire [15:0] bsc  = (m_bs > 16'd255) ? 16'd255 : m_bs;
    wire [15:0] t_bright = (bs == 8'd0) ? 16'd0 : (16'd768 + bsc);      // 0 或 768..1023

    wire [15:0] t_target = (t_dark > t_bright) ? t_dark : t_bright;
    wire [9:0]  pos_t    = (t_target > 16'd1023) ? 10'd1023 : t_target[9:0];
    // ★ v8：把"亮侧单独贡献"也送出去。AE 开启时 enh_top 用它——见下方说明。
    assign bank_pos_bright_o = (t_bright > 16'd1023) ? 10'd1023 : t_bright[9:0];
    // ★ 限速比较必须用 11 位：10 位下 pos_t+STEP 会溢出
    //   （1023+32 = 1055 -> 截成 31，于是"该升"被误判成"该降"）。
    wire [10:0] pos_tx   = {1'b0, pos_t};
    wire [10:0] pos_curx = {1'b0, bank_pos_o};
    wire [10:0] pos_upx  = pos_curx + 11'd32;
    wire [10:0] pos_dnx  = pos_tx   + 11'd32;

    // HE 资格：直方图跨度小（灰度挤在一起）且均值不离谱
    wire [7:0]  span    = p90 - p10;
    wire        mean_ok = (mean > 8'd38) && (mean < 8'd217);

    // 显示档位 = round(bank_pos/256)
    wire [10:0] rnd = {1'b0, bank_pos_o} + 11'd128;
    wire [2:0]  lvl = (rnd[10:8] > 3'd4) ? 3'd4 : rnd[10:8];

    // ★ project8-d：亮侧滞回锁存（>=3% 进入，<=1% 退出）
    //   必须在用 bs 的 always 块之前更新；复位清零。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) b_on <= 1'b0;
        else if (force_he) b_on <= 1'b0;
        else if (frame_valid) begin
            if (bright_pct >= 8'd3)      b_on <= 1'b1;
            else if (bright_pct <= 8'd1) b_on <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_pos_o    <= 10'd0;
            mode_o        <= 3'd0;
            he_eligible_o <= 1'b0;
        end else if (force_he) begin
            bank_pos_o    <= 10'd1024;         // 占位：HE 实际走 bank5，由 enh_top 决定
            mode_o        <= 3'd5;
            he_eligible_o <= 1'b1;
        end else begin
            mode_o <= lvl;
            if (frame_valid) begin
                he_eligible_o <= (span < 8'd64) && (span > 8'd8) && mean_ok;
                if (!enable)
                    bank_pos_o <= 10'd0;                      // RAW 档：直通
                else if (pos_tx > pos_upx)
                    bank_pos_o <= bank_pos_o + 10'd32;        // 限速上升（11 位比较，不会溢出）
                else if (pos_dnx < pos_curx)
                    bank_pos_o <= bank_pos_o - 10'd32;        // 限速下降
                else
                    bank_pos_o <= pos_t;
            end
        end
    end
endmodule
