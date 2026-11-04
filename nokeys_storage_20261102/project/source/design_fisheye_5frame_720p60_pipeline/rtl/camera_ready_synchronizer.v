`timescale 1ns/1ps

// Static configuration-complete level: two destination-clock FFs, never
// an SRL. Only the asynchronous input of meta_stage is a CDC exception.
module camera_ready_synchronizer (
    input wire clock, level_i,
    output wire level_o
);
    wire meta;
    GTP_DFF #(.INIT(1'b0)) meta_stage /* synthesis syn_preserve=1 syn_keep=1 */ (
        .CLK(clock), .D(level_i), .Q(meta)
    );
    GTP_DFF #(.INIT(1'b0)) sync_stage /* synthesis syn_preserve=1 syn_keep=1 */ (
        .CLK(clock), .D(meta), .Q(level_o)
    );
endmodule
