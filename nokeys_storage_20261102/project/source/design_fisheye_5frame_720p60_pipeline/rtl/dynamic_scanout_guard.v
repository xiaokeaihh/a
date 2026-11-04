`timescale 1ns/1ps
// A locked dynamic frame can be eligible once all RAW data is present, or
// after the geometry pass has proved every actual source dependency present.
// Limit the outstanding tail; live_admission also checks the service envelope
// and scan deadlines. Mode 2 still needs the complete RAW comparison pane.
module dynamic_scanout_guard #(parameter integer MAX_TAIL_ROWS=96)(
 input wire static_i,raw_complete_i,source_failed_i,dependencies_ready_i,
 input wire [10:0] committed_source_i,static_source_limit_i,total_rows_i,committed_output_i,
 input wire [1:0] mode_i,output wire source_ready_o,certificate_o
);
 wire inputs_ready=raw_complete_i||dependencies_ready_i;
 wire valid_extent=total_rows_i!=0&&committed_output_i<=total_rows_i;
 wire bounded_tail=valid_extent&&(total_rows_i-committed_output_i<=MAX_TAIL_ROWS);
 assign source_ready_o=!source_failed_i&&((mode_i==0||mode_i==2)?raw_complete_i:
    static_i?(raw_complete_i||committed_source_i>=static_source_limit_i):inputs_ready);
 assign certificate_o=!source_failed_i&&(static_i||(inputs_ready&&bounded_tail));
endmodule
