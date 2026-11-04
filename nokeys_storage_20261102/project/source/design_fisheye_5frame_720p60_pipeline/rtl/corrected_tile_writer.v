`timescale 1ns/1ps

// Collect one 128-pixel RGB565 output row and write it as eight 256-bit
// beats. The row address is supplied in the DDR controller's 32-bit words.
// The board DDR controller supplies WREADY/WLAST but has no WVALID input.
module corrected_tile_writer (
    input  wire         clock,
    input  wire         reset_n,
    input  wire         row_start_i,
    input  wire [27:0]  row_address_i,
    output wire         row_ready_o,
    input  wire         pixel_valid_i,
    input  wire [15:0]  pixel_i,
    output wire         pixel_ready_o,
    output reg          row_done_o,
    output wire         row_finishing_o,
    output reg          error_o,
    output reg  [27:0]  axi_awaddr,
    output wire [3:0]   axi_awlen,
    output wire [3:0]   axi_awid,
    output wire         axi_awvalid,
    input  wire         axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    input  wire         axi_wready,
    input  wire         axi_wlast
);
    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] FILL = 2'd1;
    localparam [1:0] ISSUE = 2'd2;
    localparam [1:0] SEND = 2'd3;

    reg [1:0] state;
    reg [6:0] pixel_count;
    reg [2:0] beat_count;
    reg [255:0] row_words [0:7];

    assign row_ready_o = (state == IDLE);
    assign pixel_ready_o = (state == FILL);
    assign axi_awlen = 4'd7;
    assign axi_awid = 4'd2;
    assign axi_awvalid = (state == ISSUE);
    assign axi_wdata = row_words[beat_count];
    assign axi_wstrb = 32'hffff_ffff;
    // Same completed write beat as row_done_o, without its one-edge delay.
    // Never asserted on W backpressure; retain the registered pulse as well.
    assign row_finishing_o = reset_n && state == SEND && axi_wready
                          && (axi_wlast || beat_count == 3'd7);

    always @(posedge clock) begin
        if (!reset_n) begin
            state <= IDLE;
            pixel_count <= 7'd0;
            beat_count <= 3'd0;
            axi_awaddr <= 28'd0;
            row_done_o <= 1'b0;
            error_o <= 1'b0;
        end else begin
            row_done_o <= 1'b0;
            if (row_start_i && state != IDLE)
                error_o <= 1'b1;
            if (pixel_valid_i && state != FILL)
                error_o <= 1'b1;
            case (state)
                IDLE: begin
                    if (row_start_i) begin
                        // One 256-bit beat is eight 32-bit DDR address words.
                        if (row_address_i[2:0] != 3'd0) begin
                            error_o <= 1'b1;
                        end else begin
                            axi_awaddr <= row_address_i;
                            pixel_count <= 7'd0;
                            error_o <= 1'b0;
                            state <= FILL;
                        end
                    end
                end
                FILL: begin
                    if (pixel_valid_i) begin
                        row_words[pixel_count[6:4]]
                                 [pixel_count[3:0]*16 +: 16] <= pixel_i;
                        if (pixel_count == 7'd127) begin
                            beat_count <= 3'd0;
                            state <= ISSUE;
                        end else begin
                            pixel_count <= pixel_count + 7'd1;
                        end
                    end
                end
                ISSUE: begin
                    if (axi_awready)
                        state <= SEND;
                end
                SEND: begin
                    if (axi_wready) begin
                        if (axi_wlast != (beat_count == 3'd7))
                            error_o <= 1'b1;
                        if (axi_wlast || beat_count == 3'd7) begin
                            row_done_o <= 1'b1;
                            state <= IDLE;
                        end else begin
                            beat_count <= beat_count + 3'd1;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
