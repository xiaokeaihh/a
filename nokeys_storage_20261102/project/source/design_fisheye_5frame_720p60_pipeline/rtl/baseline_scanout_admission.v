`timescale 1ns/1ps
// Exact fixed BASE7, reverse capture, complete-width 8-row bands only.
// The profile checks EVERY Q8 output pixel. Maximum source-line gap=6656
// clocks; band service after its last dependency arrives=24576 clocks.
// These monitored budgets never permit reads from uncommitted DDR rows.
module baseline_scanout_admission(
 input wire clock,reset_n,frame_start_i,enabled_i,render_active_i,
 input wire [10:0] source_rows_i,output_rows_i,
 input wire source_complete_i,source_failed_i,
 output wire admit_o,output reg budget_fault_o
);
 `include "source/design_fisheye_5frame_720p60_pipeline/data/baseline_scanout_profile.vh"
 reg [10:0] previous_source,previous_output;
 reg [13:0] source_gap;
 reg [14:0] service_gap;
 reg [5:0] trained;
 reg [10:0] required_q;
 reg qualified_q;
 wire source_progress=source_rows_i>previous_source;
 wire output_progress=output_rows_i>previous_output;
 wire complete_output=output_rows_i==720;
 always @(posedge clock)begin
  required_q<=baseline_band_source_rows(output_rows_i[9:3]);
  if(!reset_n||frame_start_i)begin
   previous_source<=source_rows_i;previous_output<=0;
   source_gap<=0;service_gap<=0;trained<=0;budget_fault_o<=0;qualified_q<=0;
  end else if(!render_active_i||!enabled_i)begin
   previous_source<=source_rows_i;previous_output<=output_rows_i;
   source_gap<=0;service_gap<=0;trained<=0;qualified_q<=0;
  end else begin
   previous_source<=source_rows_i;previous_output<=output_rows_i;
   qualified_q<=!source_failed_i&&!budget_fault_o&&trained>=32&&
       source_rows_i>=`BASE_LEAD_ROWS&&output_rows_i>=`BASE_PREFIX_ROWS&&
       output_rows_i<=720&&output_rows_i[2:0]==0;
   if(source_progress||source_complete_i||source_rows_i==0||complete_output)begin
    source_gap<=0;
    if(source_progress&&trained<32)trained<=trained+1'b1;
   end else if(source_gap<`BASE_LINE_CYCLES+1)source_gap<=source_gap+1'b1;
   if(output_progress||complete_output||source_rows_i<required_q)service_gap<=0;
   else if(service_gap<`BASE_BAND_CYCLES+1)service_gap<=service_gap+1'b1;
   // Sticky failure. Complete-image admission remains a safe fallback.
   if(source_failed_i||source_rows_i<previous_source||output_rows_i<previous_output||
      (!complete_output&&!source_complete_i&&source_rows_i!=0&&source_gap>=`BASE_LINE_CYCLES)||
      (!complete_output&&!output_progress&&source_rows_i>=required_q&&service_gap>=`BASE_BAND_CYCLES))
    budget_fault_o<=1;
  end
 end
 assign admit_o=enabled_i&&render_active_i&&!frame_start_i&&!source_failed_i&&
    !budget_fault_o&&qualified_q&&source_rows_i>=`BASE_LEAD_ROWS&&output_rows_i>=`BASE_PREFIX_ROWS;
endmodule
