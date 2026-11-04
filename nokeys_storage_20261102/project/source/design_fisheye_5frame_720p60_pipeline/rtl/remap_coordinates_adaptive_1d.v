`timescale 1ns/1ps
// Compatibility wrapper: mesh for fixed local views, radial tables for center.
// All paths produce 16-clock coordinate tokens; pixel interpolation is retained.
module remap_coordinates_adaptive_1d #(
 parameter X_RADIUS_FILE="",Y_RADIUS_FILE="",EVEN_GAIN_FILE="",ODD_GAIN_FILE="",EVEN_BLEND_FILE="",ODD_BLEND_FILE=""
)(
 input wire clock,reset_n,cal_write_en_i,cal_table_select_i,
 input wire [13:0] cal_write_addr_i,input wire [47:0] cal_write_data_i,
 input wire [2:0] view_i,input wire output_valid_i,
 input wire [10:0] output_x,output_y,
 output wire source_valid_o,neighborhood_valid_o,
 output wire [19:0] source_x_q8,source_y_q8,output wire [8:0] radial_blend_o
);
 wire single=(view_i<5)||(view_i==6);
 wire viewport=output_x>=320&&output_x<960&&output_y>=180&&output_y<540;
 wire [10:0] mx=single?(viewport?(output_x-11'd320)*11'd2:11'd0):output_x;
 wire [10:0] my=single?(viewport?(output_y-11'd180)*11'd2:11'd0):output_y;
 wire mv,mi,ov,oi,bv,bi;wire [19:0] mxx,myy,ox,oy,bx,by;wire [8:0] mb,ob,bb;
 remap_coordinates_mesh mesh(.clock(clock),.reset_n(reset_n),.view_i(view_i),
  .output_valid_i(output_valid_i&&view_i<6),.output_x(mx),.output_y(my),
  .source_valid_o(mv),.neighborhood_valid_o(mi),.source_x_q8(mxx),.source_y_q8(myy),.radial_blend_o(mb));
 remap_original_full center(.clock(clock),.reset_n(reset_n),
  .cal_write_en_i(cal_write_en_i),.cal_table_select_i(cal_table_select_i),.cal_write_addr_i(cal_write_addr_i),.cal_write_data_i(cal_write_data_i),
  .output_valid_i(output_valid_i&&view_i==6),.output_x(mx),.output_y(my),
  .source_valid_o(ov),.neighborhood_valid_o(oi),.source_x_q8(ox),.source_y_q8(oy),.radial_blend_o(ob));
 remap_baseline_full baseline(.clock(clock),.reset_n(reset_n),
  .cal_write_en_i(1'b0),.cal_table_select_i(1'b0),.cal_write_addr_i(14'd0),.cal_write_data_i(48'd0),
  .output_valid_i(output_valid_i&&view_i==7),.output_x(output_x),.output_y(output_y),
  .source_valid_o(bv),.neighborhood_valid_o(bi),.source_x_q8(bx),.source_y_q8(by),.radial_blend_o(bb));
 // Original radial engines have seven edges; normalize to mesh's eight.
 reg full_ready;reg [49:0] full_payload;
 always @(posedge clock)begin
  full_payload<=bv?{bi,bb,by,bx}:{oi,ob,oy,ox};
  if(!reset_n)full_ready<=0;else full_ready<=ov||bv;
 end
 reg [7:0] vp;reg [15:0] canvas;reg [49:0] data_pipe[0:7];integer j;
 always @(posedge clock)begin
  data_pipe[0]<=mv?{mi,mb,myy,mxx}:full_payload;
  for(j=1;j<8;j=j+1)data_pipe[j]<=data_pipe[j-1];
  if(!reset_n)begin vp<=0;canvas<=0;end
  else begin vp<={vp[6:0],mv||full_ready};canvas<={canvas[14:0],!single||viewport};end
 end
 assign source_valid_o=vp[7];
 assign source_x_q8=data_pipe[7][19:0];assign source_y_q8=data_pipe[7][39:20];
 assign radial_blend_o=data_pipe[7][48:40];
 assign neighborhood_valid_o=data_pipe[7][49]&&canvas[15];
endmodule
