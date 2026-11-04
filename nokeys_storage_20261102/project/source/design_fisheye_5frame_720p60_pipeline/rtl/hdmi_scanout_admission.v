`timescale 1ns/1ps
// Small metadata-only certificate for native-rate HDMI. The generated affine
// envelopes cover every exact static Q8 source dependency. A source-line and
// full-width band service budget proves all future scan deadlines. A violated
// budget disables the early path; completed-frame and camera paths stay valid.
module hdmi_scanout_admission #(
 parameter integer SOURCE_LINE_CYCLES=3200
)(
 input wire clock,reset_n,frame_start_i,enabled_i,render_active_i,
 input wire [2:0] view_i,input wire [1:0] mode_i,
 input wire [10:0] source_rows_i,output_rows_i,
 input wire source_complete_i,source_failed_i,
 output wire [7:0] status_o,
 output wire admit_o,output wire live_fault_o,output reg budget_fault_o,
 output reg [9:0] jitter_peak_o
);
 `include "source/design_fisheye_5frame_720p60_pipeline/data/hdmi_scanout_profile.vh"
 reg [2:0] view;reg [1:0] mode;reg enabled,arming;
 reg [10:0] previous_source,previous_output,minimum_source,minimum_output,required_q;
 reg [12:0] source_gap;reg [14:0] service_gap;reg [5:0] trained;
 reg native;
 reg fast_disabled;
 reg source_timing_fault,service_timing_fault;
 assign status_o={source_complete_i,service_timing_fault,source_timing_fault,fast_disabled,budget_fault_o,admit_o,arming,enabled};
 wire fast_base=view==7&&mode==3&&!fast_disabled;
 wire source_progress=source_rows_i>previous_source;
 wire output_progress=output_rows_i>previous_output;
 wire complete_output=output_rows_i==(native?360:720);
 wire raw_mode=mode==0;
 wire [14:0] service_budget=native?15'd12288:(fast_base ? `HDMI_BASE_BAND_CYCLES : 15'd24576);
 // Both independently proven BASE profiles may spend a bounded, whole-frame
 // jitter allowance. Fast/conservative proofs have 1512/1008 cycles of slack
 // AFTER its unchanged 12288-cycle fetch margin; at most 768 can be spent.
 // The allowance is shared by source and producer stalls, never renewed per
 // band. Thus max-plus completion bounds grow by at most 768 cycles total.
 wire elastic_base=view==7&&mode==3&&(
     (fast_disabled&&minimum_source==`HDMI_BASE_FALLBACK_LEAD&&minimum_output==`HDMI_BASE_FALLBACK_PREFIX)||
     (fast_base&&minimum_source==hdmi_minimum_lead(3'd7,1'b0)&&minimum_output==0));
 reg [9:0] jitter_used;
 wire source_over=!source_complete_i&&source_rows_i!=0&&source_gap>=SOURCE_LINE_CYCLES;
 wire service_over=!raw_mode&&!complete_output&&!output_progress&&
     source_rows_i>=required_q&&service_gap>=service_budget;
 wire [1:0] jitter_cost={1'b0,source_over}+{1'b0,service_over};
 wire [10:0] jitter_next={1'b0,jitter_used}+jitter_cost;
 // Equivalent credit boundary test without putting a ripple addition before
 // the fault-register input. jitter_cost is exactly 0, 1, or 2.
 wire jitter_exhausted=!elastic_base||
     (jitter_used>=`HDMI_BASE_JITTER_CYCLES&&(source_over||service_over))||
     (jitter_used==(`HDMI_BASE_JITTER_CYCLES-1)&&source_over&&service_over);
 // A slower-than-certified frame permanently returns this layout epoch to
 // the original conservative envelope, preventing repeated early-scan faults.
 always @(posedge clock)begin
  if(!reset_n)fast_disabled<=0;
  else if(frame_start_i)begin
   if(!enabled_i||view_i!=view||mode_i!=mode)fast_disabled<=0;
  end else if(fast_base&&enabled&&budget_fault_o)fast_disabled<=1;
 end
 wire fully_ready=source_complete_i&&(raw_mode||complete_output);
 wire [10:0] raw_lead=mode==2?`HDMI_SPLIT_RAW_LEAD:`HDMI_RAW_LEAD;
 // Separate the destination-bank row mux from the envelope lookup. Bounds
 // are monotonic across bands, so one older bound can only start the service
 // watchdog earlier while waiting for new dependencies: conservative, never
 // an extra allowed producer delay. Positive admission uses current rows.
 reg [6:0] band_index_q;
 always @(posedge clock)begin
  if(!reset_n||frame_start_i)band_index_q<=0;
  else band_index_q<=output_rows_i[9:3];
  required_q<=hdmi_band_source_rows(view,band_index_q);
  if(!reset_n||frame_start_i)begin
   view<=view_i;mode<=mode_i;native<=view_i<5||view_i==6;
   enabled<=0;arming<=frame_start_i;
   previous_source<=source_rows_i;previous_output<=0;
   source_gap<=0;service_gap<=0;trained<=0;budget_fault_o<=0;
   jitter_used<=0;
   source_timing_fault<=0;service_timing_fault<=0;
   minimum_source<=view_i==7&&mode_i==3&&fast_disabled&&view_i==view&&mode_i==mode ?
     `HDMI_BASE_FALLBACK_LEAD : hdmi_minimum_lead(view_i,mode_i==2);
   minimum_output<=view_i==7&&mode_i==3&&fast_disabled&&view_i==view&&mode_i==mode ?
     `HDMI_BASE_FALLBACK_PREFIX : hdmi_minimum_prefix(view_i,mode_i==2);
  end else if(arming)begin
   // Producer metadata is published on the frame-start edge; qualify it one
   // edge later so a previous bank's static/HDMI tag cannot arm a new pose.
   enabled<=enabled_i;arming<=0;
   previous_source<=source_rows_i;previous_output<=output_rows_i;
  end else if(render_active_i&&enabled)begin
   previous_source<=source_rows_i;previous_output<=output_rows_i;
   if(source_progress||source_complete_i||source_rows_i==0)begin
    source_gap<=0;if(source_progress&&trained<32)trained<=trained+1'b1;
   end else if(source_gap<SOURCE_LINE_CYCLES+`HDMI_BASE_JITTER_CYCLES+1)source_gap<=source_gap+1'b1;
   if(raw_mode||output_progress||complete_output||source_rows_i<required_q)service_gap<=0;
   else if(service_gap<service_budget+`HDMI_BASE_JITTER_CYCLES+1)service_gap<=service_gap+1'b1;
   if(elastic_base&&!budget_fault_o&&jitter_cost!=0)begin
    jitter_used<=jitter_next>`HDMI_BASE_JITTER_CYCLES ? `HDMI_BASE_JITTER_CYCLES : jitter_next[9:0];
   end
   if(source_over&&jitter_exhausted)source_timing_fault<=1;
   if(service_over&&jitter_exhausted)service_timing_fault<=1;
   if(source_failed_i||source_rows_i<previous_source||output_rows_i<previous_output||
      ((source_over||service_over)&&jitter_exhausted))
    budget_fault_o<=1;
  end
 end
 always @(posedge clock)begin
  if(!reset_n)jitter_peak_o<=0;
  else if(frame_start_i&&(!enabled_i||view_i!=view||mode_i!=mode))jitter_peak_o<=0;
  else if(jitter_used>jitter_peak_o)jitter_peak_o<=jitter_used;
 end
 wire raw_safe=mode!=0&&mode!=2||source_rows_i>=raw_lead||source_complete_i;
 wire corrected_safe=raw_mode||(source_rows_i>=minimum_source&&output_rows_i>=minimum_output);
 // Positive eligibility is monotonic within an owned source/output bank.
 // Register only that positive proof; bank release, failed RAW data, and
 // budget faults still revoke admission immediately. Clear on every grant
 // so no previous frame's eligibility can be published for a new bank.
 reg eligibility_q;
 always @(posedge clock)begin
  if(!reset_n||frame_start_i||!render_active_i||!enabled||arming)eligibility_q<=0;
  else eligibility_q<=trained>=32&&raw_safe&&corrected_safe;
 end
 assign admit_o=enabled&&!arming&&render_active_i&&!frame_start_i&&!source_failed_i&&
                !budget_fault_o&&eligibility_q;
 assign live_fault_o=enabled&&budget_fault_o&&!fully_ready;
endmodule
