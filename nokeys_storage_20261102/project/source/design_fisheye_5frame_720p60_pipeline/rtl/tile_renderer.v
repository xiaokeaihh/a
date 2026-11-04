`timescale 1ns/1ps
`include "source/design_fisheye_5frame_720p60_pipeline/data/pipeline_view_constants.vh"
// One projection/interpolation engine for fixed and frame-matched poses.
module tile_renderer #(
 parameter X_RADIUS_FILE="",Y_RADIUS_FILE="",EVEN_GAIN_FILE="",ODD_GAIN_FILE="",EVEN_BLEND_FILE="",ODD_BLEND_FILE="",ROI_FILE="",
 parameter integer USE_SHARED_SOURCE=0,
 parameter integer SOURCE_CAPTURE_REVERSE=0,
 parameter integer CACHE_SET_BITS=5
)(
 input wire source_reverse_i,
 input wire clock,reset_n,input wire [2:0] view_i,
 input wire pose_enable_i,input wire [287:0] pose_matrix_i,input wire [1439:0] pose_views_i,input wire pose_allviews_i,
 input wire start_i,input wire [1:0] source_bank_i,destination_bank_i,
 input wire abort_i,
 input wire source_complete_i,source_failed_i,input wire [10:0] source_committed_i,
 input wire [31:0] frame_id_i,tap_frame_i,
 input wire tap_valid_i,input wire [1:0] tap_bank_i,
 input wire [10:0] tap_x_i,tap_y_i,input wire [255:0] tap_pixels_i,
 output wire [159:0] cache_stats_o,
 output wire [10:0] rows_committed_o,output wire progress_valid_o,
 output wire busy_o,done_o,error_o,output wire [5:0] error_reason_o,
 input wire cal_write_en_i,cal_table_select_i,input wire [13:0] cal_write_addr_i,input wire [47:0] cal_write_data_i,input wire cal_commit_i,
 output reg calibration_loaded_o,
 output wire [27:0] axi_araddr,axi_awaddr,output wire [3:0] axi_arlen,axi_arid,axi_awlen,axi_awid,
 output wire axi_arvalid,axi_awvalid,input wire axi_arready,axi_awready,
 input wire [255:0] axi_rdata,input wire axi_rvalid,axi_rlast,
 output wire [255:0] axi_wdata,output wire [31:0] axi_wstrb,input wire axi_wready,axi_wlast,
 output wire [543:0] counters_o,
 output wire dependencies_ready_o
);
 localparam [1727:0] STATIC_BUNDLE=`PIPELINE_STATIC_BUNDLE;
 reg launch;reg [2:0] view;reg [1:0] src,dst;reg [287:0] matrix;
 reg [31:0] frame;
 reg want_pose_q;
 wire busy;
 wire want_pose=pose_enable_i&&(view_i==6||view_i==7);
 // Capture data and selection independently. The core already has its own
 // launch register stage, so move the 1728-bit mux across the existing wrapper
 // registers instead of letting an asynchronous ring match drive all data FFs.
 wire [287:0] selected_matrix=view==0 ? `PIPELINE_STATIC_LOCAL0 :
                                  want_pose_q ? matrix : view==6 ? STATIC_BUNDLE[1727:1440] : STATIC_BUNDLE[287:0];
 wire [1439:0] selected_views=STATIC_BUNDLE[1727:288];
 assign busy_o=busy||launch;
 always @(posedge clock)begin
  if(!reset_n)begin launch<=0;calibration_loaded_o<=0;want_pose_q<=0;end
  else begin
   calibration_loaded_o<=1;launch<=0;
   if(start_i&&!busy&&!launch)begin
    launch<=1;view<=view_i;src<=source_bank_i;dst<=destination_bank_i;frame<=frame_id_i;
    want_pose_q<=want_pose;matrix<=pose_matrix_i;
   end
  end
 end

 shared_pipeline_renderer #(.REQUEST_BITS(3),.SOURCE_CAPTURE_REVERSE(SOURCE_CAPTURE_REVERSE),.CACHE_SET_BITS(CACHE_SET_BITS),.ACTIVE_MATRIX_FOR_CENTER(1)) core(.source_reverse_i(source_reverse_i),.clock(clock),.reset_n(reset_n),.start_i(launch),.abort_i(abort_i),.view_i(view),.frame_id_i(frame),
  .source_bank_i(src),.destination_bank_i(dst),.matrix_i(selected_matrix),.views_i(selected_views),
  .source_complete_i(source_complete_i),.source_failed_i(source_failed_i),.source_committed_i(source_committed_i),
  .busy_o(busy),.done_o(done_o),.error_o(error_o),.error_reason_o(error_reason_o),.counters_o(counters_o),.cache_stats_o(cache_stats_o),
  .dependencies_ready_o(dependencies_ready_o),.rows_committed_o(rows_committed_o),.progress_valid_o(progress_valid_o),
  .tap_valid_i(tap_valid_i),.tap_frame_i(tap_frame_i),.tap_bank_i(tap_bank_i),
  .tap_x_i(tap_x_i),.tap_y_i(tap_y_i),.tap_pixels_i(tap_pixels_i),
  .axi_araddr(axi_araddr),.axi_arlen(axi_arlen),.axi_arid(axi_arid),.axi_arvalid(axi_arvalid),.axi_arready(axi_arready),
  .axi_rdata(axi_rdata),.axi_rvalid(axi_rvalid),.axi_rlast(axi_rlast),
  .axi_awaddr(axi_awaddr),.axi_awlen(axi_awlen),.axi_awid(axi_awid),.axi_awvalid(axi_awvalid),.axi_awready(axi_awready),
  .axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),.axi_wlast(axi_wlast));


endmodule
