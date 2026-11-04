`timescale 1ns/1ps

// DDR addresses count 32-bit words; each canonical RGB565 row is 640 words.
// Stateless translation preserves AW hold behavior and adds no pipeline cycle.
module capture_row_address #(
    parameter integer SOURCE_CAPTURE_REVERSE = 0
) (
    input wire reverse_i,
    input wire [27:0] address_i,
    output wire [27:0] address_o
);
    wire reverse_rows = reverse_i === 1'b1 || (reverse_i !== 1'b0 && SOURCE_CAPTURE_REVERSE != 0);
    generate begin: translated_rows
        wire [18:0] offset = address_i[18:0];
        wire [11:0] groups = offset[18:7];
        wire [10:0] capture_row = groups / 12'd5;
        wire [2:0] remainder = groups % 12'd5;
        wire [9:0] column_words = {remainder, offset[6:0]};
        wire [10:0] canonical_row = 11'd719 - capture_row;
        wire [18:0] row_extended = {8'd0, canonical_row};
        wire [18:0] canonical_offset = (row_extended << 9) +
                                               (row_extended << 7) + column_words;
        wire allocated_address = address_i[27:21] == 0 &&
                                 address_i[20:19] < 2'd3 && offset < 19'd460800;
        assign address_o = reverse_rows && allocated_address ?
                           {address_i[27:19], canonical_offset} : address_i;
    end endgenerate
endmodule
