`timescale 1ns/1ps

// Source-side vertical slice only. This does not enable live HDMI scanout.
module cutthrough_source_frontend #(
    parameter integer CACHE_SET_BITS=7,
    parameter integer REQUEST_BITS=2,
    parameter integer SOURCE_CAPTURE_REVERSE=0
) (
    input wire source_reverse_i,
    input wire clock, reset_n, frame_start_i,
    output wire frame_accept_o,
    input wire [31:0] frame_id_i,
    input wire [1:0] source_bank_i,
    input wire column_major_i, abort_i, source_failed_i, source_complete_i,
    input wire [10:0] source_committed_i,
    input wire request_valid_i, request_inside_i,
    output wire request_ready_o,
    input wire [10:0] request_x_i, request_y_i,
    input wire [7:0] request_tag_i,
    output wire pixel_valid_o,
    input wire pixel_ready_i,
    output wire [63:0] pixels_o,
    output wire [7:0] pixel_tag_o,
    output wire busy_o, error_o,
    output wire [4:0] activity_o,
    output wire [31:0] lookup_hits_o, lookup_misses_o, refill_count_o, tap_accepted_o, tap_dropped_o,
    input wire tap_valid_i,
    input wire [31:0] tap_frame_i,
    input wire [1:0] tap_bank_i,
    input wire [10:0] tap_x_i, tap_y_i,
    input wire [255:0] tap_pixels_i,
    output wire [27:0] axi_araddr,
    output wire [3:0] axi_arlen,
    output wire axi_arvalid,
    input wire axi_arready,
    input wire [255:0] axi_rdata,
    input wire axi_rvalid, axi_rlast
);
    wire source_reverse = source_reverse_i === 1'b1 || (source_reverse_i !== 1'b0 && SOURCE_CAPTURE_REVERSE != 0);
    wire refill_active, refill_valid, refill_ready, fill_valid, fill_ready;
    wire [31:0] refill_frame, fill_frame, lookup_frame;
    wire [1:0] refill_bank, fill_bank, lookup_bank;
    wire [10:0] refill_x, refill_y, fill_x, fill_y, lookup_x, lookup_y;
    wire [255:0] refill_pixels, fill_pixels;
    wire lookup_valid, lookup_ready, response_valid, response_hit, pool_error, reader_error;
    wire [3:0] response_miss;
    wire [63:0] response_pixels;
    assign error_o = pool_error || reader_error;

    nonblocking_source_reader #(.REQUEST_BITS(REQUEST_BITS),.SOURCE_CAPTURE_REVERSE(SOURCE_CAPTURE_REVERSE)) reader (
        .source_reverse_i(source_reverse_i),.clock(clock), .reset_n(reset_n), .frame_start_i(frame_start_i), .frame_accept_o(frame_accept_o),
        .frame_id_i(frame_id_i), .source_bank_i(source_bank_i), .abort_i(abort_i),
        .source_failed_i(source_failed_i), .source_complete_i(source_complete_i), .source_committed_i(source_committed_i),
        .request_valid_i(request_valid_i), .request_inside_i(request_inside_i), .request_ready_o(request_ready_o),
        .request_x_i(request_x_i), .request_y_i(request_y_i), .request_tag_i(request_tag_i),
        .pixel_valid_o(pixel_valid_o), .pixel_ready_i(pixel_ready_i), .pixels_o(pixels_o), .pixel_tag_o(pixel_tag_o),
        .activity_o(activity_o), .busy_o(busy_o), .refill_active_o(refill_active), .error_o(reader_error),
        .lookup_hits_o(lookup_hits_o), .lookup_misses_o(lookup_misses_o), .refill_count_o(refill_count_o),
        .lookup_valid_o(lookup_valid), .lookup_ready_i(lookup_ready), .lookup_frame_o(lookup_frame),
        .lookup_bank_o(lookup_bank), .lookup_x_o(lookup_x), .lookup_y_o(lookup_y),
        .response_valid_i(response_valid), .response_miss_i(response_miss), .response_pixels_i(response_pixels),
        .axi_araddr(axi_araddr), .axi_arlen(axi_arlen), .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rdata(axi_rdata), .axi_rvalid(axi_rvalid), .axi_rlast(axi_rlast),
        .fill_valid_o(refill_valid), .fill_ready_i(refill_ready), .fill_frame_o(refill_frame),
        .fill_bank_o(refill_bank), .fill_x_o(refill_x), .fill_y_o(refill_y), .fill_pixels_o(refill_pixels)
    );
    source_fill_arbiter fill_arbiter (
        .clock(clock), .reset_n(reset_n), .frame_start_i(frame_accept_o), .refill_active_i(refill_active),
        .tap_valid_i(tap_valid_i), .refill_valid_i(refill_valid),
        .tap_frame_i(tap_frame_i), .refill_frame_i(refill_frame), .tap_bank_i(tap_bank_i), .refill_bank_i(refill_bank),
        .tap_x_i(tap_x_i), .tap_y_i(tap_y_i), .refill_x_i(refill_x), .refill_y_i(refill_y),
        .tap_pixels_i(tap_pixels_i), .refill_pixels_i(refill_pixels), .refill_ready_o(refill_ready),
        .fill_valid_o(fill_valid), .fill_frame_o(fill_frame), .fill_bank_o(fill_bank),
        .fill_x_o(fill_x), .fill_y_o(fill_y), .fill_pixels_o(fill_pixels), .fill_ready_i(fill_ready),
        .tap_accepted_o(tap_accepted_o), .tap_dropped_o(tap_dropped_o)
    );
    associative_source_pool #(.SET_BITS(CACHE_SET_BITS)) pool (
        .clock(clock), .reset_n(reset_n), .frame_start_i(frame_accept_o), .frame_id_i(frame_id_i),
        .source_bank_i(source_bank_i), .column_major_i(column_major_i),
        .fill_valid_i(fill_valid), .fill_frame_i(fill_frame), .fill_bank_i(fill_bank),
        .fill_x_i(fill_x), .fill_y_i(fill_y), .fill_pixels_i(fill_pixels), .fill_ready_o(fill_ready),
        .lookup_valid_i(lookup_valid), .lookup_ready_o(lookup_ready),
        .lookup_frame_i(lookup_frame), .lookup_bank_i(lookup_bank), .lookup_x_i(lookup_x), .lookup_y_i(lookup_y),
        .lookup_valid_o(response_valid), .hit_o(response_hit), .miss_mask_o(response_miss),
        .pixels_o(response_pixels), .error_o(pool_error)
    );
endmodule
