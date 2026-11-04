`timescale 1ns/1ps
//==========================================================================
// enh_base.v —— 局部 base/detail 分解（高阶任务三 v2 · K×K 盒式窗口）
//
//   算法（文献里的 base/detail = 照度/反射率分解，Durand&Dorsey / Retinex 家族）：
//     base   = K×K **因果窗口**均值（行 r-K+1..r、列 c-K+1..c，即"到当前像素为止"）
//     detail = Y(当前像素) − base    （有符号）
//   曲线只作用在 base（低频）上，detail 单独核化抑制 —— 噪声不会被曲线放大。
//
//   ★ 为什么用"因果窗口"：参考像素就是**当前像素本身**，base 与 Y 同拍有效，
//     于是**不需要再存一份 Y 做对齐延迟线**，省掉一整套行缓存（约 6 个 DRAM）。
//     代价：窗口中心相对当前像素偏左上 1.5 像素 —— 对平滑色调曲线无影响。
//
//   ★ 行缓存仅存 10 位横向窗口和；原始 Y 由既有寄存器链对齐：
//     横向用移位寄存器做滑动和（本来就要存 Y），纵向求和每行只需读 1 次（每行 1 个读口）。
//     base = vsum >> (2*log2K)，纯移位，**0 乘法器**。
//
//   边界行为（仿真金标准按同样规则生成，保证逐位可比）：
//     - 帧开始前 3 行：行缓存初值为 0 -> 窗口含 0（上边界 3 行有过渡，视觉不可见）
//     - 每行开始前 3 列：横向移位寄存器清零 -> 窗口含 0（左边界 3 列同理）
//==========================================================================
module enh_base #(
    parameter integer H_ACTIVE = 1280,
    parameter integer K        = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire [7:0]  y_in,
    output reg         de_out,
    output reg  [7:0]  base_o,
    output reg  [7:0]  ymid_o
);
    localparam integer HS_W = 12;      // hsum <= 4*255 = 1020
    localparam integer NW   = 3;        // 行缓存个数；同步先读后写保留第三条历史行
    // ★ K=4 的均值要除以 16（>>4）。曾写成 SH=2 且 `vsum >> SH` -> 只除了 4，
    //   base 大 4 倍（恒定 96 输入时 base = 1536>>2 = 384，截成 8 位 = 128），
    //   v2b 整条通路因此错乱（bank0 恰好被核化项抵消才"看起来通过"）。已修为 >>KSH。
    localparam integer SH   = 2;
    localparam integer KSH  = 2 * SH;   // = 4

    // ★ 3 个行缓存用**独立数组**（不要塞进一个数组再用 wr_sel*H_ACTIVE 寻址）：
    //   Pango 对"地址里带乘法"的数组不会推断成块 RAM，会掉成分布式 RAM
    //   （实测 Distributed RAM 960、LUT 多出 1800+）。独立数组 + 纯 col 地址才能进 BRAM。
    localparam integer DW = 10; // exact 4*255 horizontal sum
    // One column word holds all three historical horizontal sums. A
    // synchronous read is followed by a write of that same column one edge
    // later, preserving the other two slices from the just-read word.
    // Column advancement separates the read and write addresses; a pause
    // does not enqueue another write. External arithmetic latency is unchanged.
    reg [29:0] history [0:H_ACTIVE-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [29:0] history_word;
    reg [11:0] write_column;
    reg [1:0] write_row;
    integer i;
    initial begin
        for(i=0;i<H_ACTIVE;i=i+1)history[i]=30'd0;
    end

    reg [11:0] col;
    reg [1:0]  wr_sel;
    reg        hs_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col <= 12'd0; wr_sel <= 2'd0; hs_d <= 1'b0;
        end else begin
            hs_d <= hs;
            if (vs) begin
                col <= 12'd0;
                wr_sel <= 2'd0;
            end else if (hs && !hs_d) begin           // 只在行头（上升沿）轮转一次
                col    <= 12'd0;
                wr_sel <= (wr_sel == NW-1) ? 2'd0 : wr_sel + 2'd1;
            end else if (de) begin
                col <= (col == H_ACTIVE-1) ? 12'd0 : col + 12'd1;
            end
        end
    end

    //------------------------------------------------ 横向滑动和（含当前像素）
    reg [7:0] y_sr0, y_sr1, y_sr2;
    wire [HS_W-1:0] hsum = y_in + y_sr0 + y_sr1 + y_sr2;    // 列 c-3..c
    always @(posedge clk) begin
        if (hs) begin
            y_sr0 <= 8'd0; y_sr1 <= 8'd0; y_sr2 <= 8'd0;    // 行头清零（左边界行为与金标准一致）
        end else if (de) begin
            y_sr0 <= y_in;
            y_sr1 <= y_sr0;
            y_sr2 <= y_sr1;
        end
    end

    //------------------------------------------------ 读 3 个历史行
    // ★ 必须**同步读**（always 块里 q <= mem[addr]）才会被推断成块 RAM；
    //   写成组合读 `wire q = mem[addr]` 会掉成分布式 RAM（实测 1320 个、LUT 多 1800+）。
    wire [DW-1:0] q0=history_word[9:0],q1=history_word[19:10],q2=history_word[29:20];
    reg [HS_W-1:0] hsum_d1;
    reg [7:0] y_d1;
    reg de_d1;
    always @(posedge clk) begin
        history_word<=history[col];
        write_column<=col;write_row<=wr_sel;
        hsum_d1<=hsum;y_d1<=y_in;de_d1<=de;
        if(de_d1)begin
            case(write_row)
                2'd0:history[write_column]<={history_word[29:10],hsum_d1[9:0]};
                2'd1:history[write_column]<={history_word[29:20],hsum_d1[9:0],history_word[9:0]};
                default:history[write_column]<={hsum_d1[9:0],history_word[19:0]};
            endcase
        end
    end

    // 同步先读后写：被覆盖的那一行仍返回 r-3，另外两行返回 r-1、r-2。
    // All three pre-write words are historical rows. Their order is
    // immaterial to the box sum, so no rotating data mux is required.
    wire [DW-1:0] s0=q0,s1=q1,s2=q2;
    // ★ 时序：vsum 原来是"4 个 12bit 相加 + 前置 mux + 移位 + LUT 地址"一整条组合路径，
    //   整机重跑时最差余量 -0.089 ns。这里把加法树打断成两级寄存器：
    //     t1 = s0+s1 ; t2 = s2+hsum_d1  （第 1 级）
    //     vsum2 = t1+t2                 （第 2 级，随后寄存到 base_o）
    wire [HS_W-1:0] sum_a = s0 + s1;
    wire [HS_W-1:0] sum_b = s2 + hsum_d1;
    reg  [HS_W-1:0] t1, t2;
    reg  [7:0] y_d2;
    reg        de_d2;
    always @(posedge clk) begin
        t1    <= sum_a;
        t2    <= sum_b;
        y_d2  <= y_d1;
        de_d2 <= de_d1;
    end
    wire [HS_W:0] vsum = {1'b0, t1} + {1'b0, t2};

    //------------------------------------------------ 输出（同步读 1 拍 + 加法树 1 拍 = 共 3 拍）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out <= 1'b0; base_o <= 8'd0; ymid_o <= 8'd0;
        end else begin
            de_out <= de_d2;
            base_o <= vsum[HS_W-1:4];          // 16 像素均值 = >>4（vsum 最大 4080 -> 255）
            ymid_o <= y_d2;
        end
    end
endmodule
