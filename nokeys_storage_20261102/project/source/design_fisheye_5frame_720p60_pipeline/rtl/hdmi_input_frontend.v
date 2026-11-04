`timescale 1ns/1ps
// MS7200 RGB888 SDR input. No scaler or frame store is inserted here.
// Only two consecutive complete frames with the expected geometry unlock DE.
// A system-clock watchdog still works if the recovered HDMI clock disappears.
module hdmi_input_frontend #(
 parameter integer H_ACTIVE=1280,
 parameter integer V_ACTIVE=720,
 parameter integer GOOD_FRAMES=2,
 parameter integer WATCHDOG_CYCLES=2700000
)(
 input wire sys_clk,reset_n,receiver_ready_i,
 input wire pixel_clk,vs_i,de_i,
 input wire [7:0] r_i,g_i,b_i,
 output reg vs_o,de_o,
 output reg [15:0] rgb_o,
 output wire sample_vs_o,sample_de_o,
 output wire format_locked_o,receiver_ready_o,source_present_o
);
 reg ready_meta,ready_sys;
 reg [2:0] vs_sys;
 reg [23:0] quiet_cycles;
 reg source_alive;
 reg [2:0] format_sync;
 reg pixel_locked;
 always @(posedge sys_clk or negedge reset_n)begin
  if(!reset_n)begin
   ready_meta<=0;ready_sys<=0;vs_sys<=0;quiet_cycles<=0;
   source_alive<=0;format_sync<=0;
  end else begin
   ready_meta<=receiver_ready_i;ready_sys<=ready_meta;
   vs_sys<={vs_sys[1:0],vs_i};format_sync<={format_sync[1:0],pixel_locked};
   if(!ready_sys)begin quiet_cycles<=0;source_alive<=0;end
   else if(vs_sys[1]&&!vs_sys[2])begin quiet_cycles<=0;source_alive<=1;end
   else if(quiet_cycles<WATCHDOG_CYCLES-1)quiet_cycles<=quiet_cycles+1'b1;
   else source_alive<=0;
  end
 end
 assign receiver_ready_o=ready_sys;
 assign source_present_o=ready_sys&&source_alive;
 assign format_locked_o=ready_sys&&source_alive&&format_sync[2];
 wire source_enable=reset_n&&ready_sys&&source_alive;
 reg [2:0] release_reset;
 always @(posedge pixel_clk or negedge source_enable)
  if(!source_enable)release_reset<=0;
  else release_reset<={release_reset[1:0],1'b1};
 wire pixel_reset_n=release_reset[2];
 // Capture the external bus before counters or qualification logic.
 // RGB and sync share the same two-cycle latency through the frontend.
 reg captured_vs,captured_de;
 assign sample_vs_o=captured_vs;assign sample_de_o=captured_de;
 reg [15:0] captured_rgb;
 always @(posedge pixel_clk or negedge pixel_reset_n)begin
  if(!pixel_reset_n)begin captured_vs<=1;captured_de<=0;captured_rgb<=0;end
  else begin captured_vs<=vs_i;captured_de<=de_i;captured_rgb<={r_i[7:3],g_i[7:2],b_i[7:3]};end
 end
 reg previous_vs,previous_de,frame_seen,frame_bad;
 reg [12:0] line_pixels,frame_lines;
 reg [3:0] good_count;
 always @(posedge pixel_clk or negedge pixel_reset_n)begin
  if(!pixel_reset_n)begin
   previous_vs<=0;previous_de<=0;frame_seen<=0;frame_bad<=0;
   line_pixels<=0;frame_lines<=0;good_count<=0;pixel_locked<=0;
   vs_o<=1;de_o<=0;rgb_o<=0;
  end else begin
   previous_vs<=captured_vs;previous_de<=captured_de;
   vs_o<=captured_vs;
   rgb_o<=captured_rgb;
   de_o<=captured_de&&pixel_locked&&frame_seen&&!captured_vs&&!frame_bad&&
         line_pixels<H_ACTIVE&&frame_lines<V_ACTIVE;
   if(captured_vs&&!previous_vs)begin
    if(frame_seen&&!frame_bad&&!previous_de&&frame_lines==V_ACTIVE)begin
     if(good_count<GOOD_FRAMES)good_count<=good_count+1'b1;
     if(good_count>=GOOD_FRAMES-1)pixel_locked<=1;
    end else begin good_count<=0;pixel_locked<=0;end
    line_pixels<=0;frame_lines<=0;frame_bad<=0;frame_seen<=1;
   end else if(!captured_vs&&frame_seen)begin
    if(captured_de)begin
     if(line_pixels<13'h1fff)line_pixels<=line_pixels+1'b1;
     if(line_pixels>=H_ACTIVE||frame_lines>=V_ACTIVE)begin
      frame_bad<=1;pixel_locked<=0;good_count<=0;
     end
    end
    if(previous_de&&!captured_de)begin
     if(line_pixels!=H_ACTIVE)begin frame_bad<=1;pixel_locked<=0;good_count<=0;end
     if(frame_lines<13'h1fff)frame_lines<=frame_lines+1'b1;
     line_pixels<=0;
    end
   end
  end
 end
endmodule
