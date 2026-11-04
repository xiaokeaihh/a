// Generated from the existing exact Q8 BASE7 mapping; no pixel LUT changes.
`define BASE_LEAD_ROWS 11'd279
`define BASE_PREFIX_ROWS 11'd88
`define BASE_LINE_CYCLES 6656
`define BASE_BAND_CYCLES 24576
function [10:0] baseline_band_source_rows;
 input [6:0] band;
 reg [10:0] band_times_15;
 begin
 band_times_15={band,4'b0}-{4'b0,band};
 baseline_band_source_rows=band<90 ? 11'd236+(band_times_15>>2) : 11'd720;
 end
endfunction
