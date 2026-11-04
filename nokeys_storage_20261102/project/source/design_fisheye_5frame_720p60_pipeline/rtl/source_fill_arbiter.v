`timescale 1ns/1ps

// A skipped camera tap is still archived by the original RAW writer.
// Refill holds VALID/payload until accepted. During repair, taps must not
// evict freshly refilled data before its retry lookup has completed.
module source_fill_arbiter (
    input wire clock, reset_n, frame_start_i, refill_active_i,
    input wire tap_valid_i, refill_valid_i,
    input wire [31:0] tap_frame_i, refill_frame_i,
    input wire [1:0] tap_bank_i, refill_bank_i,
    input wire [10:0] tap_x_i, tap_y_i, refill_x_i, refill_y_i,
    input wire [255:0] tap_pixels_i, refill_pixels_i,
    output wire refill_ready_o, fill_valid_o,
    output wire [31:0] fill_frame_o,
    output wire [1:0] fill_bank_o,
    output wire [10:0] fill_x_o, fill_y_o,
    output wire [255:0] fill_pixels_o,
    input wire fill_ready_i,
    output reg [31:0] tap_accepted_o, tap_dropped_o
);
    wire select_refill = refill_valid_i;
    wire eligible_tap = tap_valid_i && !refill_active_i && !refill_valid_i;
    assign fill_valid_o = reset_n && !frame_start_i && (select_refill || eligible_tap);
    assign fill_frame_o = select_refill ? refill_frame_i : tap_frame_i;
    assign fill_bank_o = select_refill ? refill_bank_i : tap_bank_i;
    assign fill_x_o = select_refill ? refill_x_i : tap_x_i;
    assign fill_y_o = select_refill ? refill_y_i : tap_y_i;
    assign fill_pixels_o = select_refill ? refill_pixels_i : tap_pixels_i;
    assign refill_ready_o = fill_ready_i && fill_valid_o && select_refill;
    always @(posedge clock) begin
        if (!reset_n || frame_start_i) begin tap_accepted_o <= 0; tap_dropped_o <= 0; end
        else if (tap_valid_i) begin
            if (eligible_tap && fill_valid_o && fill_ready_i) tap_accepted_o <= tap_accepted_o + 1'b1;
            else tap_dropped_o <= tap_dropped_o + 1'b1;
        end
    end
endmodule
