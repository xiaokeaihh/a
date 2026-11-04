`timescale 1ns/1ps
//======================================================================
// enh_lut.v —— 6 bank × 256 项增强查找表（高阶任务三 · 720p60 版）
//
//   bank0 = 直通(γ=1.00)   bank1 = γ0.45（夜间提亮）  bank2 = γ0.70（偏暗）
//   bank3 = γ1.40（偏亮）  bank4 = γ1.60（强光压暗）  bank5 = HE（帧末由 enh_stats 写入）
//
//   ★ 资源取舍：
//     增强曲线**按 R/G/B 三个通道各自查表**（工业上常见的 RGB tone curve），
//     所以需要 3 个独立读口 -> 用 3 份相同内容的表（每份 1536×8bit），
//     合起来约 36 Kbit，占 1~2 个 DRM；**不用一个乘法器**。
//     三个通道共用同一条曲线（曲线由亮度统计得出），这样不会出现"分通道各自均衡"
//     带来的偏色，比逐通道独立 HE 稳得多。
//
//   gamma 预置表由 Python 生成（data/gamma_presets.mem），
//     上电用 $readmemh 初始化（Pango ADS 支持，已在 OSD 工程实测通过）。
//   读延迟 1 拍；bank 只在帧边界（VSYNC）切换 -> 不会撕裂。
//======================================================================
module enh_lut #(
    parameter PRESET_FILE = "gamma_presets.mem"
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] bank,          // 当前生效 bank
    input  wire [7:0] r_in,          // 三个通道的 8bit 输入
    input  wire [7:0] g_in,
    input  wire [7:0] b_in,
    output reg  [7:0] r_out,
    output reg  [7:0] g_out,
    output reg  [7:0] b_out,
    // HE 表写入（只写 bank5）
    input  wire       we,
    input  wire [7:0] waddr,
    input  wire [7:0] wdata
`ifdef SIM_DEBUG_PORT
    ,
    // 只在仿真里存在的表读回口（综合时不定义该宏 -> 不占资源）
    // 用途：testbench 逐项核对 256 项 HE 表，做到位精确验证
    input  wire [10:0] dbg_addr,
    output reg  [7:0]  dbg_data
`endif
);
    localparam integer DEPTH = 6 * 256;      // 1536

    reg [7:0] lut_r [0:DEPTH-1];
    reg [7:0] lut_g [0:DEPTH-1];
    reg [7:0] lut_b [0:DEPTH-1];

    initial begin
        $readmemh(PRESET_FILE, lut_r);
        $readmemh(PRESET_FILE, lut_g);
        $readmemh(PRESET_FILE, lut_b);
    end

    wire [10:0] a_r = {bank, r_in};
    wire [10:0] a_g = {bank, g_in};
    wire [10:0] a_b = {bank, b_in};
    wire [10:0] a_w = {3'b101, waddr};       // HE 永远写 bank5

    always @(posedge clk) begin
        r_out <= lut_r[a_r];
        g_out <= lut_g[a_g];
        b_out <= lut_b[a_b];
        if (we) begin
            lut_r[a_w] <= wdata;
            lut_g[a_w] <= wdata;
            lut_b[a_w] <= wdata;
        end
`ifdef SIM_DEBUG_PORT
        dbg_data <= lut_r[dbg_addr];
`endif
    end
endmodule

// Project pixel inputs are RGB565 expanded with zero-filled low bits. Keep
// the generic 8-bit enh_lut above unchanged for other callers. Only unreachable
// HE entries are omitted here; curve values and one-edge old-data reads remain.
module enh_lut_rgb565 #(
    parameter PRESET_FILE = "gamma_presets.mem"
)(
    input wire clk,
    input wire [2:0] bank,
    input wire [7:0] r_in,g_in,b_in,
    output reg [7:0] r_out,g_out,b_out,
    input wire we,
    input wire [7:0] waddr,wdata
`ifdef SIM_DEBUG_PORT
    ,input wire [10:0] dbg_addr,output reg [7:0] dbg_data
`endif
);
    reg [7:0] presets [0:1535];
    initial $readmemh(PRESET_FILE,presets);
    wire [7:0] he_r,he_b;
    wire [15:0] he_green_segments;
    wire [7:0] he_g=g_in[7] ? he_green_segments[15:8] : he_green_segments[7:0];

    // The calibrated preset file initializes bank 5 to identity. Preserve that
    // initial state exactly; rst does not erase an HE table in the old module.
    function [31:0] identity_plane;
        input integer base,bit_index,step;
        integer row,value;
        begin
            for(row=0;row<32;row=row+1)begin
                value=(base+row)*step;
                identity_plane[row]=value[bit_index];
            end
        end
    endfunction
    genvar lane,segment;
    generate for(lane=0;lane<4;lane=lane+1)begin: red_blue
        GTP_RAM32X2DP #(.INIT_0(identity_plane(0,lane*2,8)),
                       .INIT_1(identity_plane(0,lane*2+1,8))) red_table (
            .DO(he_r[lane*2+:2]),.DI(wdata[lane*2+:2]),
            .RADDR(r_in[7:3]),.WADDR(waddr[7:3]),.WCLK(clk),.WE(we&&waddr[2:0]==0));
        GTP_RAM32X2DP #(.INIT_0(identity_plane(0,lane*2,8)),
                       .INIT_1(identity_plane(0,lane*2+1,8))) blue_table (
            .DO(he_b[lane*2+:2]),.DI(wdata[lane*2+:2]),
            .RADDR(b_in[7:3]),.WADDR(waddr[7:3]),.WCLK(clk),.WE(we&&waddr[2:0]==0));
        for(segment=0;segment<2;segment=segment+1)begin: green
            GTP_RAM32X2DP #(.INIT_0(identity_plane(segment*32,lane*2,4)),
                           .INIT_1(identity_plane(segment*32,lane*2+1,4))) green_table (
                .DO(he_green_segments[segment*8+lane*2+:2]),.DI(wdata[lane*2+:2]),
                .RADDR(g_in[6:2]),.WADDR(waddr[6:2]),.WCLK(clk),
                .WE(we&&waddr[1:0]==0&&waddr[7]==segment));
        end
    end endgenerate

    always @(posedge clk)begin
        r_out<=bank==5 ? he_r : presets[{bank,r_in[7:3],3'b0}];
        g_out<=bank==5 ? he_g : presets[{bank,g_in[7:2],2'b0}];
        b_out<=bank==5 ? he_b : presets[{bank,b_in[7:3],3'b0}];
    end
`ifdef SIM_DEBUG_PORT
    // Test-only full table readback does not introduce hardware RAM.
    reg [7:0] debug_he [0:255];
    integer debug_index;
    initial for(debug_index=0;debug_index<256;debug_index=debug_index+1)
        debug_he[debug_index]=debug_index;
    always @(posedge clk)begin
        if(we)debug_he[waddr]<=wdata;
        dbg_data<=dbg_addr[10:8]==5 ? debug_he[dbg_addr[7:0]] : presets[dbg_addr];
    end
`endif
endmodule

// Balanced tone mapping, RGB565 full-range expansion, common Q8 RGB gain.
// Stage 1: edge-aware 2-tap horizontal denoise + luminance/max.
// Stage 2: synchronous tone/headroom ROMs and pixel alignment.
// Stage 3: common gain, rounding, output. RAW bypass is bit-exact, 3 clocks.
// Neighbour is invalidated at line/frame/content/apply boundaries; no frame RAM.
module enh_balanced_rgb565 (
 input wire clk,rst_n,vs,hs,de,content,apply_i,
 input wire [2:0] bank,input wire [15:0] rgb_i,
 output wire de_o,output reg [15:0] rgb_o
);
 wire [7:0] r={rgb_i[15:11],rgb_i[15:13]};
 wire [7:0] g={rgb_i[10:5],rgb_i[10:9]};
 wire [7:0] b={rgb_i[4:0],rgb_i[4:2]};
 reg [7:0] pr,pg,pb;
 reg previous_valid;
 wire [7:0] dr=(r>pr)?r-pr:pr-r;
 wire [7:0] dg=(g>pg)?g-pg:pg-g;
 wire [7:0] db=(b>pb)?b-pb:pb-b;
 wire [7:0] maxrg=(r>g)?r:g;
 wire [7:0] mx=(maxrg>b)?maxrg:b;
 wire [7:0] threshold=(mx<96)?24:12;
 wire smooth=previous_valid && de && content && apply_i && !hs && !vs &&
             (dr<=threshold)&&(dg<=threshold)&&(db<=threshold);
 wire [8:0] sr={1'b0,r}+{1'b0,pr}+9'd1;
 wire [8:0] sg={1'b0,g}+{1'b0,pg}+9'd1;
 wire [8:0] sb={1'b0,b}+{1'b0,pb}+9'd1;
 wire [7:0] fr=smooth?sr[8:1]:r;
 wire [7:0] fg=smooth?sg[8:1]:g;
 wire [7:0] fb=smooth?sb[8:1]:b;
 // Explicitly widened shift/add luminance: (R+2G+B)/4, neutral-axis exact.
 wire [9:0] ysum={2'b0,fr}+{1'b0,fg,1'b0}+{2'b0,fb}+10'd2;
 wire [7:0] fmaxrg=(fr>fg)?fr:fg;
 wire [7:0] fmax=(fmaxrg>fb)?fmaxrg:fb;
 reg [7:0] r1,g1,b1,y1,max1,r2,g2,b2;
 reg [15:0] raw1,raw2;
 reg a1,a2;
 reg [2:0] dp,bank1;
 reg [9:0] tone_rom[0:1535];
 reg [9:0] head_rom[0:255];
 initial begin
   $readmemh("tone_gain_balanced.mem",tone_rom);
   $readmemh("tone_headroom_balanced.mem",head_rom);
 end
 reg [9:0] tone2,head2;
 always @(posedge clk) begin
   tone2<=tone_rom[{bank1,y1}];
   head2<=head_rom[max1];
 end
 wire [9:0] gain=(tone2>head2)?head2:tone2;
 wire [17:0] rp=r2*gain+18'd128;
 wire [17:0] gp=g2*gain+18'd128;
 wire [17:0] bp=b2*gain+18'd128;
 wire [7:0] ro=(rp[17:8]>255)?8'd255:rp[15:8];
 wire [7:0] go=(gp[17:8]>255)?8'd255:gp[15:8];
 wire [7:0] bo=(bp[17:8]>255)?8'd255:bp[15:8];
 assign de_o=dp[2];
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     pr<=0;pg<=0;pb<=0;previous_valid<=0;
     r1<=0;g1<=0;b1<=0;y1<=0;max1<=0;bank1<=0;
     r2<=0;g2<=0;b2<=0;raw1<=0;raw2<=0;a1<=0;a2<=0;
     dp<=0;rgb_o<=0;
   end else begin
     pr<=r;pg<=g;pb<=b;
     previous_valid<=de && content && apply_i && !hs && !vs;
     r1<=fr;g1<=fg;b1<=fb;y1<=ysum[9:2];max1<=fmax;
     bank1<=(bank<=4)?bank:0;
     r2<=r1;g2<=g1;b2<=b1;
     raw1<=rgb_i;raw2<=raw1;
     a1<=apply_i && content;a2<=a1;dp<={dp[1:0],de};
     rgb_o<=a2?{ro[7:3],go[7:2],bo[7:3]}:raw2;
   end
 end
endmodule
