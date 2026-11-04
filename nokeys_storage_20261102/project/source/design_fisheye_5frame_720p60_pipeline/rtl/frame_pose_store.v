`timescale 1ns/1ps
// Pose ring is indexed by camera frame ID, never by rendering/display time.
// A bounded wait falls back to the unchanged baseline instead of freezing RAW.
module frame_pose_store(
 input wire clock,reset_n,input wire [31:0] hardware_tick_i,
 input wire camera_accept_i,camera_first_i,input wire [1:0] camera_bank_i,
 input wire [31:0] frame_id_i,frame_tick_i,
 input wire pose_valid_i,input wire [31:0] pose_frame_i,pose_tick_i,
 input wire [287:0] pose_matrix_i,
 input wire [1439:0] pose_views_i,input wire pose_allviews_i,
 input wire [2:0] pose_view_i,requested_view_i,
 input wire [7:0] pose_sequence_i,requested_sequence_i,input wire pose_tagged_i,
 input wire [1:0] pending_bank_i,render_bank_i,
 output wire pending_ready_o,render_ready_o,
 output wire [287:0] render_matrix_o,
 output wire [1439:0] render_views_o,output wire render_allviews_o
);
 reg [31:0] raw_id[0:2],raw_tick[0:2];reg [2:0] raw_valid;
 reg [31:0] ids[0:15],ticks[0:15];
 reg [15:0] record_tagged;
 reg [2:0] target_view[0:15];reg [7:0] target_sequence[0:15];
 // Unconnected requested_view in historical standalone fixtures means BASE7.
 wire [2:0] request_view=(requested_view_i===3'd6)?3'd6:3'd7;
 reg [15:0] valid;
 wire [3:0] render_slot=raw_id[render_bank_i][3:0];
 // Compare all camera banks in parallel, BEFORE the render-bank mux.
 // This removes the bank-select -> heavily loaded pose address -> wide
 // identity compare chain from ready without adding a clock edge.
 wire [2:0] bank_matches /* synthesis syn_keep=1 */;
 genvar bank;
 generate for(bank=0;bank<3;bank=bank+1)begin: match_bank
  wire [3:0] slot=raw_id[bank][3:0];
  assign bank_matches[bank]=valid[slot]&&ids[slot]==raw_id[bank]&&ticks[slot]==raw_tick[bank]&&
    (record_tagged[slot]?(target_view[slot]==request_view&&target_sequence[slot]==requested_sequence_i):request_view==7);
 end endgenerate
 assign pending_ready_o=raw_valid[pending_bank_i]&&(bank_matches[pending_bank_i]||(hardware_tick_i-raw_tick[pending_bank_i]>=32'd3000));
 assign render_ready_o=raw_valid[render_bank_i]&&bank_matches[render_bank_i];
 pose_record_ram records (
  .clock(clock), .write_enable(reset_n&&pose_valid_i),
  .read_address(render_slot), .write_address(pose_frame_i[3:0]),
  .write_data(pose_matrix_i),
  .read_data(render_matrix_o)
 );
 assign render_views_o=1440'd0;assign render_allviews_o=1'b0;
 always @(posedge clock)begin
  if(!reset_n)begin valid<=0;raw_valid<=0;record_tagged<=0;end
  else begin
   if(camera_accept_i)raw_valid[camera_bank_i]<=0;
   if(camera_first_i)begin raw_id[camera_bank_i]<=frame_id_i;raw_tick[camera_bank_i]<=frame_tick_i;raw_valid[camera_bank_i]<=1;end
   if(pose_valid_i)begin
    ids[pose_frame_i[3:0]]<=pose_frame_i;ticks[pose_frame_i[3:0]]<=pose_tick_i;
    valid[pose_frame_i[3:0]]<=1;
    record_tagged[pose_frame_i[3:0]]<=pose_tagged_i===1'b1;
    target_view[pose_frame_i[3:0]]<=pose_view_i;
    target_sequence[pose_frame_i[3:0]]<=pose_sequence_i;
   end
  end
 end
endmodule
