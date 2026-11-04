`timescale 1ns/1ps

// Sixteen 288-bit active-view matrices, synchronous write and asynchronous read.
// Logos2 supports native 32x2 DP RAM (16x4 DP is unsupported in this PDS).
// The unused upper 16 addresses are never accessed. No
// serialization, truncation, added pipeline edge or capacity reduction.
module pose_record_ram (
    input wire clock, write_enable,
    input wire [3:0] read_address, write_address,
    input wire [287:0] write_data,
    output wire [287:0] read_data
);
    genvar lane;
    generate for (lane=0; lane<144; lane=lane+1) begin: word_lane
        GTP_RAM32X2DP memory (
            .DO(read_data[lane*2+:2]), .DI(write_data[lane*2+:2]),
            .RADDR({1'b0,read_address}), .WADDR({1'b0,write_address}),
            .WCLK(clock), .WE(write_enable)
        );
    end endgenerate
endmodule
