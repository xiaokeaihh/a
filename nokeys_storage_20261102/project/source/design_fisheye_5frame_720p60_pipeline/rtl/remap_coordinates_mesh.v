`timescale 1ns/1ps
// Five fixed views, 16-pixel mesh, four parity banks; one token per clock.
// Nodes hold x Q8, y Q8 and the existing adaptive interpolation weight.
// Explicit 4096+1024 ROM banks avoid PDS inference corrupting the high-address
// portion of a 4715-entry ROM. The read edge and coordinate latency stay fixed.
module remap_coordinates_mesh (
 input wire clock,reset_n,output_valid_i,
 input wire [2:0] view_i,
 input wire [10:0] output_x,output_y,
 output reg source_valid_o,neighborhood_valid_o,
 output reg [19:0] source_x_q8,source_y_q8,
 output reg [8:0] radial_blend_o
);
 reg [48:0] bank00_main[0:4095] /* synthesis syn_ramstyle="block_ram" */;
 reg [48:0] bank00_tail[0:1023] /* synthesis syn_ramstyle="block_ram" */;
 reg [48:0] bank01_main[0:4095] /* synthesis syn_ramstyle="block_ram" */;
 reg [48:0] bank01_tail[0:1023] /* synthesis syn_ramstyle="block_ram" */;
 reg [48:0] bank10_main[0:4095] /* synthesis syn_ramstyle="block_ram" */;
 reg [48:0] bank10_tail[0:1023] /* synthesis syn_ramstyle="block_ram" */;
 reg [48:0] bank11_main[0:4095] /* synthesis syn_ramstyle="block_ram" */;
 reg [48:0] bank11_tail[0:1023] /* synthesis syn_ramstyle="block_ram" */;
 reg [22:0] spans[0:3599] /* synthesis syn_ramstyle="block_ram" */;
 initial begin
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/mesh_anchor_00_main.mem",bank00_main);
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/mesh_anchor_00_tail.mem",bank00_tail);
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/mesh_anchor_01_main.mem",bank01_main);
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/mesh_anchor_01_tail.mem",bank01_tail);
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/mesh_anchor_10_main.mem",bank10_main);
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/mesh_anchor_10_tail.mem",bank10_tail);
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/mesh_anchor_11_main.mem",bank11_main);
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/mesh_anchor_11_tail.mem",bank11_tail);
  $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/rect_spans.mem",spans);
 end
 wire quad=view_i==5;
 wire [2:0] ev=quad?(output_y>=360?(output_x<640?3'd1:3'd2):(output_x<640?3'd3:3'd4)):(view_i<5?view_i:3'd0);
 wire [10:0] x=quad?(output_x<640?output_x*11'd2:(output_x-11'd640)*11'd2):output_x;
 wire [10:0] y=quad?(output_y<360?output_y*11'd2:(output_y-11'd360)*11'd2):output_y;
 wire [6:0] ar=y[10:4],ac=x[10:4];
 reg [12:0] page0,a00,a01,a10,a11;
 reg [9:0] er0,orr0;
 reg [5:0] ec0,oc0;
 reg rp0,cp0,rp1,cp1,rp2,cp2;
 reg [3:0] fx0,fy0,fx1,fy1,fx2,fy2,fx3,fy3,fy4,fy5;
 reg [22:0] span0;reg [10:0] x0;
 reg region1,region2,region3,region4,region5,region6;
 reg [48:0] b00,b01,b10,b11,tl,tr,bl,br;
 reg [24:0] hl[0:5],hr[0:5];reg [19:0] h[0:5];
 reg [24:0] vt[0:2],vb[0:2];
 reg [6:0] vp;
 wire [4:0] wx=5'd16-{1'b0,fx3},wy=5'd16-{1'b0,fy5};
 wire [25:0] sxsum={1'b0,vt[0]}+{1'b0,vb[0]}+26'd8;
 wire [25:0] sysum={1'b0,vt[1]}+{1'b0,vb[1]}+26'd8;
 wire [25:0] bsum={1'b0,vt[2]}+{1'b0,vb[2]}+26'd8;
 integer j;
 always @(posedge clock) begin
  page0<=ev*13'd943;er0<=((ar+7'd1)>>1)*10'd41;orr0<=(ar>>1)*10'd41;
  ec0<=(ac+7'd1)>>1;oc0<=ac>>1;rp0<=ar[0];cp0<=ac[0];fx0<=x[3:0];fy0<=y[3:0];
  span0<=spans[ev*12'd720+(y<720?y:11'd0)];x0<=x;
  region1<=span0[22]&&x0>=span0[10:0]&&x0<=span0[21:11];
  a00<=page0+er0+ec0;a01<=page0+er0+oc0;a10<=page0+orr0+ec0;a11<=page0+orr0+oc0;
  rp1<=rp0;cp1<=cp0;fx1<=fx0;fy1<=fy0;region2<=region1;
  b00<=a00[12]?bank00_tail[a00[9:0]]:bank00_main[a00[11:0]];b01<=a01[12]?bank01_tail[a01[9:0]]:bank01_main[a01[11:0]];b10<=a10[12]?bank10_tail[a10[9:0]]:bank10_main[a10[11:0]];b11<=a11[12]?bank11_tail[a11[9:0]]:bank11_main[a11[11:0]];
  rp2<=rp1;cp2<=cp1;fx2<=fx1;fy2<=fy1;region3<=region2;
  tl<=rp2?(cp2?b11:b10):(cp2?b01:b00);
  tr<=rp2?(cp2?b10:b11):(cp2?b00:b01);
  bl<=rp2?(cp2?b01:b00):(cp2?b11:b10);
  br<=rp2?(cp2?b00:b01):(cp2?b10:b11);
  fx3<=fx2;fy3<=fy2;region4<=region3;
  hl[0]<=tl[19:0]*wx;hr[0]<=tr[19:0]*fx3;hl[1]<=bl[19:0]*wx;hr[1]<=br[19:0]*fx3;
  hl[2]<=tl[39:20]*wx;hr[2]<=tr[39:20]*fx3;hl[3]<=bl[39:20]*wx;hr[3]<=br[39:20]*fx3;
  hl[4]<=tl[48:40]*wx;hr[4]<=tr[48:40]*fx3;hl[5]<=bl[48:40]*wx;hr[5]<=br[48:40]*fx3;
  fy4<=fy3;region5<=region4;
  for(j=0;j<6;j=j+1)h[j]<=(hl[j]+hr[j]+25'd8)>>4;
  fy5<=fy4;region6<=region5;
  vt[0]<=h[0]*wy;vb[0]<=h[1]*fy5;vt[1]<=h[2]*wy;vb[1]<=h[3]*fy5;vt[2]<=h[4]*wy;vb[2]<=h[5]*fy5;
  source_x_q8<=sxsum[23:4];source_y_q8<=sysum[23:4];radial_blend_o<=bsum[12:4];
  neighborhood_valid_o<=region6&&(sxsum[23:12]<1279)&&(sysum[23:12]<719);
  if(!reset_n)begin vp<=0;source_valid_o<=0;neighborhood_valid_o<=0;end
  else begin vp<={vp[5:0],output_valid_i};source_valid_o<=vp[6];end
 end
endmodule
