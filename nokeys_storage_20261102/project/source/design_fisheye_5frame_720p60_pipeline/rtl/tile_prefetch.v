`timescale 1ns/1ps

// Read one aligned source tile from a 256-bit DDR AXI port and serialize
// each beat into RGB565 pixels for source_tile_cache. One AXI burst per row.
// The DDR IP does not expose RREADY, so the entire row is received before
// issuing another request; the 16-beat FIFO accommodates the widest row.
module tile_prefetch #(
    // The Pango DDR address counts 32-bit words, not bytes.
    parameter integer FRAME_STRIDE_WORDS = 640
) (
    input  wire         clock,
    input  wire         reset_n,
    input  wire         start_i,
    input  wire [27:0]  frame_base_i,
    input  wire [10:0]  tile_x0_i,
    input  wire [10:0]  tile_y0_i,
    input  wire [7:0]   tile_width_i,
    input  wire [7:0]   tile_height_i,
    output wire         busy_o,
    output reg          done_o,
    output reg          error_o,
    output reg  [27:0]  axi_araddr,
    output reg  [3:0]   axi_arlen,
    output wire [3:0]   axi_arid,
    output wire         axi_arvalid,
    input  wire         axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire         axi_rvalid,
    input  wire         axi_rlast,
    output reg          pixel_valid_o,
    output reg  [7:0]   pixel_x_o,
    output reg  [5:0]   pixel_y_o,
    output reg  [15:0]  pixel_o
);
    localparam [2:0] IDLE = 3'd0;
    localparam [2:0] ISSUE = 3'd1;
    localparam [2:0] RECEIVE = 3'd2;
    localparam [2:0] DRAIN = 3'd3;

    reg [2:0] state;
    reg [27:0] frame_base;
    reg [10:0] tile_x0;
    reg [10:0] tile_y0;
    reg [7:0] tile_height;
    reg [3:0] beats_per_row;
    reg [5:0] row_index;
    reg [3:0] received_beats;
    reg [3:0] output_beat;
    reg [3:0] output_pixel;
    reg [255:0] row_beats [0:15];

    assign axi_arvalid = (state == ISSUE);
    assign axi_arid = 4'd1;
    assign busy_o = (state != IDLE);

    always @(posedge clock) begin
        if (!reset_n) begin
            state <= IDLE;
            frame_base <= 28'd0;
            tile_x0 <= 11'd0;
            tile_y0 <= 11'd0;
            tile_height <= 8'd0;
            beats_per_row <= 4'd0;
            row_index <= 6'd0;
            received_beats <= 4'd0;
            output_beat <= 4'd0;
            output_pixel <= 4'd0;
            axi_araddr <= 28'd0;
            axi_arlen <= 4'd0;
            pixel_valid_o <= 1'b0;
            pixel_x_o <= 8'd0;
            pixel_y_o <= 6'd0;
            pixel_o <= 16'd0;
            done_o <= 1'b0;
            error_o <= 1'b0;
        end else begin
            pixel_valid_o <= 1'b0;
            done_o <= 1'b0;
            case (state)
                IDLE: begin
                    if (start_i) begin
                        error_o <= 1'b0;
                        if (tile_width_i == 0 || tile_width_i > 240
                            || tile_height_i == 0 || tile_height_i > 64
                            || tile_width_i[3:0] != 0
                            || tile_height_i[0] != 0
                            || tile_x0_i[3:0] != 0
                            || tile_y0_i[0] != 0) begin
                            error_o <= 1'b1;
                        end else begin
                            frame_base <= frame_base_i;
                            tile_x0 <= tile_x0_i;
                            tile_y0 <= tile_y0_i;
                            tile_height <= tile_height_i;
                            beats_per_row <= tile_width_i[7:4];
                            row_index <= 6'd0;
                            axi_araddr <= frame_base_i
                                        + tile_y0_i * FRAME_STRIDE_WORDS
                                        + (tile_x0_i >> 1);
                            axi_arlen <= tile_width_i[7:4] - 4'd1;
                            state <= ISSUE;
                        end
                    end
                end
                ISSUE: begin
                    if (axi_arready) begin
                        received_beats <= 4'd0;
                        state <= RECEIVE;
                    end
                end
                RECEIVE: begin
                    if (axi_rvalid) begin
                        row_beats[received_beats] <= axi_rdata;
                        if (axi_rlast != (received_beats == beats_per_row - 4'd1))
                            error_o <= 1'b1;
                        if (received_beats == beats_per_row - 4'd1) begin
                            output_beat <= 4'd0;
                            output_pixel <= 4'd0;
                            state <= DRAIN;
                        end else begin
                            received_beats <= received_beats + 4'd1;
                        end
                    end
                end
                DRAIN: begin
                    pixel_valid_o <= 1'b1;
                    pixel_x_o <= {output_beat, output_pixel};
                    pixel_y_o <= row_index;
                    pixel_o <= row_beats[output_beat][output_pixel*16 +: 16];
                    if (output_pixel == 4'd15) begin
                        output_pixel <= 4'd0;
                        if (output_beat == beats_per_row - 4'd1) begin
                            output_beat <= 4'd0;
                            if (row_index == tile_height - 8'd1) begin
                                done_o <= 1'b1;
                                state <= IDLE;
                            end else begin
                                row_index <= row_index + 6'd1;
                                axi_araddr <= frame_base
                                            + (tile_y0 + row_index + 12'd1)
                                              * FRAME_STRIDE_WORDS
                                            + (tile_x0 >> 1);
                                state <= ISSUE;
                            end
                        end else begin
                            output_beat <= output_beat + 4'd1;
                        end
                    end else begin
                        output_pixel <= output_pixel + 4'd1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
