`timescale 1ns/1ps
// Switch only while the raster is held in reset. NORMAL mode intentionally
// permits recovery from an RX clock stopped at either level; active video is
// never allowed through the handover interval. Configuration clocks stay local.
module hdmi_output_clock #(
 parameter integer MIN_FRAME_CYCLES=445500,
 parameter integer MAX_FRAME_CYCLES=454500,
 parameter integer CLOCK_TIMEOUT=2700,
 parameter integer SWITCH_GUARD=540,
 parameter integer BOUNDARY_TIMEOUT=540000
)(
 input wire sys_clk,reset_n,local_pixel_clk,rx_pixel_clk,rx_vsync,
 input wire source_enabled_i,requested_i,frame_end_toggle_i,
 output wire pixel_clk_o,
 output reg pixel_reset_n_o,
 output wire following_o,
 output reg [15:0] switches_o
);
 reg [7:0] heartbeat_div;
 always @(posedge rx_pixel_clk or negedge reset_n)
  if(!reset_n)heartbeat_div<=0;else heartbeat_div<=heartbeat_div+1'b1;
 reg [2:0] heartbeat_sync,vs_sync,end_sync;
 reg [1:0] enable_sync,request_sync;
 reg [12:0] quiet;
 reg [19:0] frame_cycles;
 reg frame_seen;
 reg [2:0] good_frames;
 wire heartbeat=heartbeat_sync[2]^heartbeat_sync[1];
 // VS is active high. Synchronizer tap [1] is newer than [2].
 wire source_rise=vs_sync[1]&&!vs_sync[2];
 wire boundary=end_sync[2]^end_sync[1];
 wire desired=request_sync[1]&&enable_sync[1]&&good_frames>=3&&quiet<CLOCK_TIMEOUT;
 reg selected;
 reg [1:0] state;
 reg [19:0] guard;
 localparam RUN=0,WAIT_BOUNDARY=1,HOLD=2,SETTLE=3;
 assign following_o=selected&&pixel_reset_n_o;
 GTP_CLKBUFGMUX #(.TRIGGER_MODE("NORMAL"),.SIM_DEVICE("LOGOS2")) u_pixel_mux(
  .CLKOUT(pixel_clk_o),.CLKIN0(local_pixel_clk),.CLKIN1(rx_pixel_clk),.SEL(selected));
 always @(posedge sys_clk or negedge reset_n)begin
  if(!reset_n)begin
   heartbeat_sync<=0;vs_sync<=0;end_sync<=0;enable_sync<=0;request_sync<=0;
   quiet<=CLOCK_TIMEOUT;frame_cycles<=0;frame_seen<=0;good_frames<=0;
   selected<=0;pixel_reset_n_o<=0;switches_o<=0;state<=SETTLE;guard<=0;
  end else begin
   heartbeat_sync<={heartbeat_sync[1:0],heartbeat_div[7]};
   vs_sync<={vs_sync[1:0],rx_vsync};end_sync<={end_sync[1:0],frame_end_toggle_i};
   enable_sync<={enable_sync[0],source_enabled_i};request_sync<={request_sync[0],requested_i};
   if(heartbeat)quiet<=0;else if(quiet<CLOCK_TIMEOUT)quiet<=quiet+1'b1;
   if(frame_cycles<MAX_FRAME_CYCLES+1)frame_cycles<=frame_cycles+1'b1;
   if(!enable_sync[1]||quiet>=CLOCK_TIMEOUT)begin good_frames<=0;frame_seen<=0;end
   else if(source_rise)begin
    frame_cycles<=0;frame_seen<=1;
    if(frame_seen&&frame_cycles>=MIN_FRAME_CYCLES&&frame_cycles<=MAX_FRAME_CYCLES)begin
     if(good_frames<3)good_frames<=good_frames+1'b1;
    end else good_frames<=0;
   end else if(frame_cycles>MAX_FRAME_CYCLES)good_frames<=0;
   case(state)
    RUN:if(desired!=selected)begin state<=WAIT_BOUNDARY;guard<=0;end
    WAIT_BOUNDARY:begin
     if(desired==selected)state<=RUN;
     else if(boundary||(selected&&quiet>=CLOCK_TIMEOUT)||guard>=BOUNDARY_TIMEOUT)begin
      pixel_reset_n_o<=0;guard<=0;state<=HOLD;
     end else guard<=guard+1'b1;
    end
    HOLD:if(guard>=SWITCH_GUARD)begin
     selected<=desired;switches_o<=switches_o+1'b1;guard<=0;state<=SETTLE;
    end else guard<=guard+1'b1;
    SETTLE:if(guard>=SWITCH_GUARD)begin
     pixel_reset_n_o<=1;guard<=0;state<=RUN;
    end else guard<=guard+1'b1;
   endcase
  end
 end
endmodule
