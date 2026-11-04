// Exact Q8 dependency upper envelopes and exhaustive future-scan proof.
`define HDMI_SOURCE_LINE_CYCLES 3200
`define HDMI_BASE_BAND_CYCLES 22000
`define HDMI_RAW_LEAD 11'd106
`define HDMI_SPLIT_RAW_LEAD 11'd261
`define HDMI_BASE_FALLBACK_LEAD 11'd243
`define HDMI_BASE_FALLBACK_PREFIX 11'd88
`define HDMI_BASE_JITTER_CYCLES 10'd768
function [10:0] hdmi_band_source_rows;
 input [2:0] view;input [6:0] band;
 reg [17:0] amount;
 begin case(view)
 3'd0:amount=18'd217+(({11'd0,band}*18'd54)>>3);
 3'd1:amount=18'd309+(({11'd0,band}*18'd56)>>3);
 3'd2:amount=18'd302+(({11'd0,band}*18'd57)>>3);
 3'd3:amount=18'd190+(({11'd0,band}*18'd48)>>3);
 3'd4:amount=18'd190+(({11'd0,band}*18'd48)>>3);
 3'd5:amount=18'd191+(({11'd0,band}*18'd47)>>3);
 3'd6:amount=18'd289+(({11'd0,band}*18'd59)>>3);
 3'd7:amount=18'd202+(({11'd0,band}*18'd31)>>3);
 default:amount=720;
 endcase
 hdmi_band_source_rows=amount>720?720:amount[10:0];
 end
endfunction
function [10:0] hdmi_minimum_lead;
 input [2:0] view;input compare_mode;
 begin case({compare_mode,view})
 4'd0:hdmi_minimum_lead=11'd1023;
 4'd8:hdmi_minimum_lead=11'd70;
 4'd1:hdmi_minimum_lead=11'd1023;
 4'd9:hdmi_minimum_lead=11'd168;
 4'd2:hdmi_minimum_lead=11'd1023;
 4'd10:hdmi_minimum_lead=11'd166;
 4'd3:hdmi_minimum_lead=11'd1023;
 4'd11:hdmi_minimum_lead=11'd43;
 4'd4:hdmi_minimum_lead=11'd1023;
 4'd12:hdmi_minimum_lead=11'd43;
 4'd5:hdmi_minimum_lead=11'd254;
 4'd13:hdmi_minimum_lead=11'd370;
 4'd6:hdmi_minimum_lead=11'd1023;
 4'd14:hdmi_minimum_lead=11'd164;
 4'd7:hdmi_minimum_lead=11'd196;
 4'd15:hdmi_minimum_lead=11'd319;
 default:hdmi_minimum_lead=11'd1023;
 endcase end
endfunction
function [10:0] hdmi_minimum_prefix;
 input [2:0] view;input compare_mode;
 begin case({compare_mode,view})
 4'd0:hdmi_minimum_prefix=11'd1023;
 4'd8:hdmi_minimum_prefix=11'd0;
 4'd1:hdmi_minimum_prefix=11'd1023;
 4'd9:hdmi_minimum_prefix=11'd0;
 4'd2:hdmi_minimum_prefix=11'd1023;
 4'd10:hdmi_minimum_prefix=11'd0;
 4'd3:hdmi_minimum_prefix=11'd1023;
 4'd11:hdmi_minimum_prefix=11'd0;
 4'd4:hdmi_minimum_prefix=11'd1023;
 4'd12:hdmi_minimum_prefix=11'd0;
 4'd5:hdmi_minimum_prefix=11'd88;
 4'd13:hdmi_minimum_prefix=11'd248;
 4'd6:hdmi_minimum_prefix=11'd1023;
 4'd14:hdmi_minimum_prefix=11'd0;
 4'd7:hdmi_minimum_prefix=11'd0;
 4'd15:hdmi_minimum_prefix=11'd248;
 default:hdmi_minimum_prefix=11'd1023;
 endcase end
endfunction
