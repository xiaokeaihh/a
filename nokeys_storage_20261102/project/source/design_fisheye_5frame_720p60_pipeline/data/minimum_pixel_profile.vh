// Exhaustive static Q8 minimum-pixel proof; valid only for shared RX/output clock.
localparam integer MINIMUM_SOURCE_POINTS=12;
function [21:0] minimum_source_point;input [3:0] slot;begin case(slot)
 4'd0:minimum_source_point={11'd409,11'd212};
 4'd1:minimum_source_point={11'd410,11'd212};
 4'd2:minimum_source_point={11'd712,11'd282};
 4'd3:minimum_source_point={11'd567,11'd282};
 4'd4:minimum_source_point={11'd568,11'd282};
 4'd5:minimum_source_point={11'd754,11'd185};
 4'd6:minimum_source_point={11'd537,11'd185};
 4'd7:minimum_source_point={11'd538,11'd185};
 4'd8:minimum_source_point={11'd960,11'd448};
 4'd9:minimum_source_point={11'd664,11'd584};
 4'd10:minimum_source_point={11'd386,11'd199};
 4'd11:minimum_source_point={11'd387,11'd199};
 default:minimum_source_point=22'h3fffff;endcase end endfunction
function [24:0] minimum_output_point;input [3:0] profile;begin case(profile)
 4'd0:minimum_output_point={4'd0,11'd320,10'd180};
 4'd1:minimum_output_point={4'd2,11'd951,10'd180};
 4'd2:minimum_output_point={4'd3,11'd320,10'd180};
 4'd3:minimum_output_point={4'd5,11'd957,10'd180};
 4'd4:minimum_output_point={4'd6,11'd320,10'd180};
 4'd5:minimum_output_point={4'd5,11'd637,10'd0};
 4'd6:minimum_output_point={4'd9,11'd651,10'd509};
 4'd7:minimum_output_point={4'd10,11'd0,10'd0};
 4'd8:minimum_output_point={4'd1,11'd641,10'd180};
 4'd9:minimum_output_point={4'd2,11'd1271,10'd180};
 4'd10:minimum_output_point={4'd4,11'd641,10'd180};
 4'd11:minimum_output_point={4'd5,11'd1277,10'd180};
 4'd12:minimum_output_point={4'd7,11'd641,10'd180};
 4'd13:minimum_output_point={4'd8,11'd1217,10'd359};
 4'd14:minimum_output_point={4'd9,11'd971,10'd509};
 4'd15:minimum_output_point={4'd11,11'd641,10'd180};
 default:minimum_output_point=25'h1ffffff;endcase end endfunction
