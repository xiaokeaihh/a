`timescale 1ns/1ps

// Refill one aligned 16x2 block using two one-beat row reads. The controller
// has no RREADY; a returned row stays in this register until the pool accepts it.
module source_block_refill #(
    parameter integer SOURCE_CAPTURE_REVERSE = 0
) (
    input wire clock, reset_n, start_i, abort_i,
    input wire [31:0] frame_id_i,
    input wire [1:0] source_bank_i,
    input wire [10:0] source_x_i, source_y_i, source_committed_i,
    input wire source_complete_i, source_failed_i,
    output wire busy_o,
    output reg done_o, error_o,
    output wire [27:0] axi_araddr,
    output wire [3:0] axi_arlen,
    output wire axi_arvalid,
    input wire axi_arready,
    input wire [255:0] axi_rdata,
    input wire axi_rvalid, axi_rlast,
    output wire fill_valid_o,
    input wire fill_ready_i,
    output wire [31:0] fill_frame_o,
    output wire [1:0] fill_bank_o,
    output wire [10:0] fill_x_o, fill_y_o,
    output wire [255:0] fill_pixels_o
);
    localparam IDLE = 3'd0, WAIT_SOURCE = 3'd1, ADDRESS = 3'd2;
    localparam RECEIVE = 3'd3, FILL = 3'd4, DRAIN = 3'd5;
    reg [2:0] state;
    reg cancelled, second_row;
    reg [31:0] frame;
    reg [1:0] bank;
    reg [10:0] x0, y0;
    reg [255:0] row_pixels;
    wire cancellation_now = cancelled || abort_i || source_failed_i;
    wire [27:0] source_row = {17'd0, y0} + second_row;
    wire [27:0] row_words = (source_row << 9) + (source_row << 7);
    // Count is captured rows, not a canonical top-to-bottom watermark.
    wire [10:0] required_capture_rows = SOURCE_CAPTURE_REVERSE != 0 ?
                                       11'd720 - y0 : y0 + 11'd2;

    assign busy_o = state != IDLE;
    assign axi_araddr = {7'd0, bank, 19'd0} + row_words + (x0 >> 1);
    assign axi_arlen = 4'd0;
    // Once announced, VALID/address persist even through an abort until READY.
    assign axi_arvalid = state == ADDRESS;
    assign fill_valid_o = state == FILL && !cancellation_now;
    assign fill_frame_o = frame;
    assign fill_bank_o = bank;
    assign fill_x_o = x0;
    assign fill_y_o = y0 + second_row;
    assign fill_pixels_o = row_pixels;

    always @(posedge clock) begin
        if (!reset_n) begin
            state <= IDLE; cancelled <= 0; second_row <= 0;
            frame <= 0; bank <= 0; x0 <= 0; y0 <= 0; row_pixels <= 0;
            done_o <= 0; error_o <= 0;
        end else begin
            done_o <= 0;
            if (state != IDLE && (abort_i || source_failed_i)) begin
                cancelled <= 1;
                if (source_failed_i) error_o <= 1;
            end
            case (state)
                IDLE: if (start_i) begin
                    frame <= frame_id_i; bank <= source_bank_i;
                    x0 <= source_x_i; y0 <= source_y_i;
                    second_row <= 0; cancelled <= 0; error_o <= 0;
                    if (source_bank_i >= 3 || source_x_i > 1264 || source_x_i[3:0] != 0 ||
                        source_y_i > 718 || source_y_i[0] != 0) begin
                        error_o <= 1; done_o <= 1;
                    end else state <= WAIT_SOURCE;
                end
                WAIT_SOURCE: begin
                    if (cancellation_now) begin state <= IDLE; done_o <= 1; end
                    else if (source_complete_i || source_committed_i >= required_capture_rows)
                        state <= ADDRESS;
                end
                ADDRESS: if (axi_arready) state <= RECEIVE;
                RECEIVE: if (axi_rvalid) begin
                    if (!axi_rlast) begin
                        error_o <= 1;
                        state <= DRAIN;
                    end else if (cancellation_now) begin
                        state <= IDLE; done_o <= 1;
                    end else begin
                        row_pixels <= axi_rdata;
                        state <= FILL;
                    end
                end
                FILL: begin
                    if (cancellation_now) begin state <= IDLE; done_o <= 1; end
                    else if (fill_ready_i) begin
                        if (second_row) begin state <= IDLE; done_o <= 1; end
                        else begin second_row <= 1; state <= ADDRESS; end
                    end
                end
                DRAIN: if (axi_rvalid && axi_rlast) begin state <= IDLE; done_o <= 1; end
                default: begin state <= IDLE; error_o <= 1; done_o <= 1; end
            endcase
        end
    end
endmodule
