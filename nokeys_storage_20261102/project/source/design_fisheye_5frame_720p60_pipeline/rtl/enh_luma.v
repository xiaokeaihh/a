`timescale 1ns/1ps
//======================================================================
// enh_luma.v —— RGB565 -> 8bit 亮度（高阶任务三 · 720p60 版）
//
//   公式与软件参考完全一致： Y = (77R + 150G + 29B) >> 8
//   R8 = {r5,3'b000}, G8 = {g6,2'b00}, B8 = {b5,3'b000}（与本工程显示通路同口径）
//
//   资源取舍：**不用乘法器**。77/150/29 全部拆成移位相加：
//     77R  = R<<6 + R<<3 + R<<2 + R        (64+8+4+1)
//     150G = G<<7 + G<<4 + G<<2 + G<<1     (128+16+4+2)
//     29B  = B<<5 - B<<1 - B               (32-2-1)
//   拆成两级流水（先 R+G，再 +B）保证 74.25 MHz 下的时序余量。
//   延迟固定 2 拍（与 enh_top 里的像素通路严格对齐）。
//======================================================================
module enh_luma (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [15:0] rgb565,
    output reg         de_o,
    output reg  [7:0]  y_o
);
    wire [7:0] r8 = {rgb565[15:11], 3'b000};
    wire [7:0] g8 = {rgb565[10:5],  2'b00};
    wire [7:0] b8 = {rgb565[4:0],   3'b000};

    // 第 1 级：77R + 150G
    wire [15:0] rg = (r8 << 6) + (r8 << 3) + (r8 << 2) + r8
                   + (g8 << 7) + (g8 << 4) + (g8 << 2) + (g8 << 1);
    // 29B
    wire [15:0] b29 = (b8 << 5) - (b8 << 1) - b8;

    // ★ 两级流水必须**同时**寄存 R+G、29B 和 de。
    //   这里踩过一个很隐蔽的坑：只寄存了 rg，b29 仍是组合的当前像素，
    //   结果 Y 把"上一个像素的 R、G"和"当前像素的 B"混在一起 ——
    //   灰度图案下 Y 会整体差 1（136 算成 135），直方图桶位全偏、和值差 0.1%，
    //   而"亮度提取"这一级本身看起来完全正常。
    reg [15:0] rg_r, b29_r;
    reg        de_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rg_r <= 16'd0;
            b29_r <= 16'd0;
            de_r <= 1'b0;
        end else begin
            rg_r  <= rg;
            b29_r <= b29;
            de_r  <= de;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_o  <= 8'd0;
            de_o <= 1'b0;
        end else begin
            y_o  <= (rg_r + b29_r) >> 8;    // 最大 (77+150+29)*255>>8 = 255
            de_o <= de_r;
        end
    end
endmodule
