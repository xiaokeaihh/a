`timescale 1ns/1ps
// Test-only first-word-fall-through FIFO model. Production uses Pango IP.
module video_async_fifo #(
    parameter WR_DATA_WIDTH=32, RD_DATA_WIDTH=256,
    parameter WR_DEPTH_WIDTH=12, RD_DEPTH_WIDTH=9,
    parameter ALMOST_FULL=3840, ALMOST_EMPTY=120
) (
    input wr_clk, wr_rst, input [WR_DATA_WIDTH-1:0] wr_data, input wr_en,
    output wr_full, almost_full, output [WR_DEPTH_WIDTH:0] wr_level,
    input rd_clk, rd_rst, output [RD_DATA_WIDTH-1:0] rd_data,
    input rd_en, output rd_empty, rd_valid, almost_empty,
    output [RD_DEPTH_WIDTH:0] rd_level
);
    localparam integer CAP_BITS = (1<<WR_DEPTH_WIDTH)*WR_DATA_WIDTH;
    reg [CAP_BITS-1:0] mem;
    integer wbits=0, rbits=0;
    wire [31:0] available = wbits-rbits;
    assign wr_full = available+WR_DATA_WIDTH > CAP_BITS;
    assign rd_valid = available >= RD_DATA_WIDTH;
    assign rd_empty = !rd_valid;
    assign almost_full = available >= ALMOST_FULL*WR_DATA_WIDTH;
    assign almost_empty = available <= ALMOST_EMPTY*RD_DATA_WIDTH;
    assign wr_level = available/WR_DATA_WIDTH;
    assign rd_level = available/RD_DATA_WIDTH;
    assign rd_data = mem[(rbits%CAP_BITS) +: RD_DATA_WIDTH];
    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) wbits <= 0;
        else if (wr_en && !wr_full) begin
            mem[(wbits%CAP_BITS) +: WR_DATA_WIDTH] <= wr_data;
            wbits <= wbits+WR_DATA_WIDTH;
        end
    end
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) rbits <= 0;
        else if (rd_en && rd_valid) rbits <= rbits+RD_DATA_WIDTH;
    end
endmodule
