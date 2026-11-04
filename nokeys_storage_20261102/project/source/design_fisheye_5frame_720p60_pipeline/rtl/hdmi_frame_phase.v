`timescale 1ns/1ps
`include "source/design_fisheye_5frame_720p60_pipeline/data/hdmi_scanout_phase.vh"
// Source-clock alignment with continuous video during layout/profile changes.
// Only initial acquisition can hold the raster. Later changes slew by at most
// one vertical-blank line per frame, leaving every active row/pixel intact.
module hdmi_frame_phase #(
 parameter integer FRAME_PIXELS=1237500,
 parameter integer LINE_PIXELS=1650,
 parameter integer GUARD_PIXELS=13200,
 parameter integer PROFILE_FRAMES=8,
 parameter integer MAX_READY_CYCLES=6250000,
 parameter integer LATE_GUARD_CYCLES=33333,
 parameter integer FASTER_GUARD_CYCLES=125000,
 parameter integer CERTIFIED_BASE_PHASE_PIXELS=`HDMI_BASE_CERTIFIED_PHASE_PIXELS,
 parameter integer FAST_BASE_PHASE_PIXELS=`HDMI_BASE_FAST_PHASE_PIXELS
)(
 input wire pixel_clk,reset_n,following_i,source_vs_i,frame_end_i,raster_vs_i,
 input wire certified_base_i,fast_profile_i,
 input wire [4:0] epoch_i,
 input wire ready_toggle_i,input wire [23:0] ready_cycles_i,
 output reg raster_enable_o,
 output reg locked_o,
 output reg [20:0] target_phase_o,
 output reg [23:0] worst_ready_cycles_o,
 output reg [15:0] acquisitions_o,
 output reg [20:0] last_ready_phase_o,last_output_phase_o,
 output wire [2:0] state_o,
 output wire certified_base_active_o,
 output wire [1:0] phase_adjust_o
);
 reg [1:0] certified_base_sync,fast_profile_sync;
 reg fast_profile_epoch;
 reg certified_epoch;
 reg [2:0] source_vs_sync,ready_sync;
 reg [1:0] following_sync;
 reg [4:0] epoch_meta,epoch_sync,epoch;
 wire certified_base=certified_base_sync[1]&&epoch_sync==5'b11111;
 assign certified_base_active_o=certified_base&&following_sync[1];
 reg [23:0] delay_meta,delay_sync;
 reg [21:0] source_phase;
 reg source_seen;
 reg [1:0] valid_periods;
 reg [3:0] samples;
 reg [2:0] state;
 assign state_o=state;
 localparam TRAIN=0,WAIT_END=1,ALIGN=2,LOCKED=3,CALCULATE=4,NORMALIZE=5;
 reg [1:0] late_count;
 // Startup ownership/DDR warmup can publish a much slower ready sample.
 // Re-evaluate two complete clean windows after every slow episode. Smooth
 // porch slews keep these corrections from interrupting the raster.
 reg [23:0] recovery_window_max,recovery_previous_max;
 reg [3:0] recovery_samples;
 reg recovery_candidate,recovery_used;
 reg aligned_once;
 wire [21:0] phase_forward=target_phase_o>=last_output_phase_o ?
   {1'b0,target_phase_o}-{1'b0,last_output_phase_o} :
   {1'b0,target_phase_o}+FRAME_PIXELS-{1'b0,last_output_phase_o};
 wire phase_close=phase_forward<=LINE_PIXELS||phase_forward>=FRAME_PIXELS-LINE_PIXELS;
 // 01 adds a front-porch line; 10 removes one. sync_vg latches this only
 // after active video, so a changing view cannot truncate its current frame.
 assign phase_adjust_o=following_sync[1]&&aligned_once&&state==LOCKED&&!phase_close ?
   (phase_forward<FRAME_PIXELS/2 ? 2'b01 : 2'b10) : 2'b00;
 reg [26:0] scaled_delay_q;
 reg [21:0] wait_cycles;
 reg raster_vs_d;
 wire source_start=source_vs_sync[1]&&!source_vs_sync[2];
 wire ready_event=ready_sync[2]^ready_sync[1];
 wire good_delay=delay_sync!=0&&delay_sync<=MAX_READY_CYCLES;
 wire [23:0] worst_next=delay_sync>worst_ready_cycles_o?delay_sync:worst_ready_cycles_o;
 wire [23:0] recovery_peak=delay_sync>recovery_window_max?delay_sync:recovery_window_max;
 wire [23:0] recovery_pair_max=recovery_peak>recovery_previous_max?recovery_peak:recovery_previous_max;
 wire recovery_faster={1'b0,recovery_peak}+FASTER_GUARD_CYCLES<{1'b0,worst_ready_cycles_o};
 // DDR clock is 125MHz; 3/5 conservatively overestimates 74.25MHz output
 // cycles by ~1%. The extra eight raster lines cover CDC and service jitter.
 wire target_now=source_seen&&((source_start&&target_phase_o==0)||
   (!source_start&&source_phase+1'b1==target_phase_o));
 always @(posedge pixel_clk or negedge reset_n)begin
  if(!reset_n)begin
   certified_base_sync<=0;certified_epoch<=0;fast_profile_sync<=0;fast_profile_epoch<=0;
   source_vs_sync<=0;ready_sync<=0;following_sync<=0;epoch_meta<=0;epoch_sync<=0;epoch<=0;
   delay_meta<=0;delay_sync<=0;source_phase<=0;source_seen<=0;valid_periods<=0;
   samples<=0;state<=TRAIN;late_count<=0;wait_cycles<=0;scaled_delay_q<=0;
   raster_enable_o<=1;locked_o<=0;target_phase_o<=0;worst_ready_cycles_o<=0;acquisitions_o<=0;
   raster_vs_d<=0;last_ready_phase_o<=0;last_output_phase_o<=0;
   recovery_window_max<=0;recovery_previous_max<=0;recovery_samples<=0;recovery_candidate<=0;recovery_used<=0;aligned_once<=0;
  end else begin
   certified_base_sync<={certified_base_sync[0],certified_base_i===1'b1};
   fast_profile_sync<={fast_profile_sync[0],fast_profile_i===1'b1};
   source_vs_sync<={source_vs_sync[1:0],source_vs_i};ready_sync<={ready_sync[1:0],ready_toggle_i};
   following_sync<={following_sync[0],following_i};
   epoch_meta<=epoch_i;epoch_sync<=epoch_meta;delay_meta<=ready_cycles_i;delay_sync<=delay_meta;
   raster_vs_d<=raster_vs_i;
   if(ready_event&&source_seen)last_ready_phase_o<=source_phase[20:0];
   if(raster_vs_i&&!raster_vs_d&&source_seen)last_output_phase_o<=source_phase[20:0];
   if(source_start)begin
    source_phase<=0;source_seen<=1;
    if(source_seen&&source_phase>=FRAME_PIXELS-3&&source_phase<=FRAME_PIXELS+1)begin
     if(valid_periods<2)valid_periods<=valid_periods+1'b1;
    end else valid_periods<=0;
   end else if(source_phase<2*FRAME_PIXELS)source_phase<=source_phase+1'b1;
   if(!following_sync[1]||epoch_sync!=epoch||certified_base!=certified_epoch||(certified_base&&fast_profile_sync[1]!=fast_profile_epoch)||source_phase>=2*FRAME_PIXELS)begin
    certified_epoch<=certified_base;fast_profile_epoch<=fast_profile_sync[1];
    epoch<=epoch_sync;samples<=0;state<=TRAIN;locked_o<=0;raster_enable_o<=1;
    worst_ready_cycles_o<=0;late_count<=0;wait_cycles<=0;
    recovery_window_max<=0;recovery_previous_max<=0;recovery_samples<=0;recovery_candidate<=0;recovery_used<=0;
    if(!following_sync[1]||source_phase>=2*FRAME_PIXELS)aligned_once<=0;
    if(!following_sync[1])begin source_seen<=0;valid_periods<=0;source_phase<=0;end
   end else case(state)
    TRAIN:begin
     raster_enable_o<=1;locked_o<=0;
     if(certified_base&&valid_periods==2)begin
      // A readiness sample includes COR-bank ownership waits, which depend on
      // this output phase. Chasing that sample creates a positive feedback
      // loop. BASE7 has a proven static service envelope: choose its epoch
      // independently, then let real committed-prefix admission decide what
      // can be displayed. Other profiles retain measured phase acquisition.
      target_phase_o<=fast_profile_sync[1]?FAST_BASE_PHASE_PIXELS:CERTIFIED_BASE_PHASE_PIXELS;
      if(aligned_once)state<=LOCKED;else state<=WAIT_END;
     end else if(ready_event&&good_delay&&valid_periods==2)begin
      worst_ready_cycles_o<=worst_next;
      if(samples>=PROFILE_FRAMES-1)begin
       samples<=0;
       // A free-running raster can vary bank-retirement waits by more than
       // the steady-state recovery threshold. Waiting for two matching
       // maxima can prevent acquisition itself. Discard the first warmup
       // window, then always acquire from the latest complete window's max.
       // Late-frame protection and continuous faster recovery remain active.
       if(recovery_candidate)begin
        worst_ready_cycles_o<=worst_next;
        recovery_candidate<=0;recovery_samples<=0;recovery_window_max<=0;state<=CALCULATE;
       end else begin
        recovery_previous_max<=worst_next;recovery_candidate<=1;worst_ready_cycles_o<=0;
       end
      end
      else samples<=samples+1'b1;
     end
    end
    CALCULATE:begin
     scaled_delay_q<=({3'd0,worst_ready_cycles_o}*3+4)/5+GUARD_PIXELS;state<=NORMALIZE;
    end
    NORMALIZE:begin
     if(scaled_delay_q>=3*FRAME_PIXELS)target_phase_o<=scaled_delay_q-3*FRAME_PIXELS;
     else if(scaled_delay_q>=2*FRAME_PIXELS)target_phase_o<=scaled_delay_q-2*FRAME_PIXELS;
     else if(scaled_delay_q>=FRAME_PIXELS)target_phase_o<=scaled_delay_q-FRAME_PIXELS;
     else target_phase_o<=scaled_delay_q[20:0];
     if(aligned_once)begin state<=LOCKED;locked_o<=0;end
     else state<=WAIT_END;
    end
    WAIT_END:if(valid_periods!=2)state<=TRAIN;
     else if(frame_end_i)begin raster_enable_o<=0;wait_cycles<=0;state<=ALIGN;end
    ALIGN:begin
     if(target_now&&valid_periods==2)begin
      raster_enable_o<=1;locked_o<=1;aligned_once<=1;state<=LOCKED;acquisitions_o<=acquisitions_o+1'b1;late_count<=0;
      recovery_window_max<=0;recovery_previous_max<=0;recovery_samples<=0;recovery_candidate<=0;
     end else if(wait_cycles>=2*FRAME_PIXELS-1)begin raster_enable_o<=1;state<=TRAIN;end
     else wait_cycles<=wait_cycles+1'b1;
    end
    LOCKED:begin
     // Frame feedback, not a completed training window, determines lock.
     if(raster_vs_i&&!raster_vs_d)begin
      locked_o<=phase_close;
      if(phase_close&&!locked_o)acquisitions_o<=acquisitions_o+1'b1;
     end
     if(valid_periods!=2)begin locked_o<=0;state<=TRAIN;samples<=0;worst_ready_cycles_o<=0;recovery_candidate<=0;end
     else if(certified_base)begin
      if(ready_event&&good_delay)worst_ready_cycles_o<=worst_next;
     end else if(ready_event&&good_delay)begin
      if(delay_sync>worst_ready_cycles_o+LATE_GUARD_CYCLES)begin
       if(late_count==2)begin
        worst_ready_cycles_o<=delay_sync;state<=TRAIN;samples<=1;locked_o<=0;late_count<=0;recovery_candidate<=0;
       end else late_count<=late_count+1'b1;
      end else late_count<=0;
      // Continuous blanking slews cannot cause the old stop/restart flashing.
      // Re-evaluate every stable window, including after a later slow episode.
      begin
       if(recovery_samples>=PROFILE_FRAMES-1)begin
        recovery_samples<=0;recovery_window_max<=0;
        if(recovery_faster)begin
         if(recovery_candidate&&{1'b0,recovery_pair_max}+FASTER_GUARD_CYCLES<{1'b0,worst_ready_cycles_o})begin
          worst_ready_cycles_o<=recovery_pair_max;state<=CALCULATE;locked_o<=0;late_count<=0;
          recovery_used<=1;recovery_candidate<=0;
         end else begin recovery_previous_max<=recovery_peak;recovery_candidate<=1;end
        end else begin recovery_previous_max<=0;recovery_candidate<=0;end
       end else begin recovery_samples<=recovery_samples+1'b1;recovery_window_max<=recovery_peak;end
      end
     end
    end
   endcase
  end
 end
endmodule
