`timescale 1ns / 1ps

// Thin project-local wrapper around Pango's RAM based asynchronous FIFO.
// The depth parameters are expressed independently in write/read words; both
// sides must describe the same total number of stored bits.
module video_async_fifo #(
    parameter WR_DATA_WIDTH  = 16,
    parameter RD_DATA_WIDTH  = 256,
    parameter WR_DEPTH_WIDTH = 12,
    parameter RD_DEPTH_WIDTH = 8,
    parameter ALMOST_FULL    = 240,
    parameter ALMOST_EMPTY   = 16
) (
    input  wire                     wr_clk,
    input  wire                     wr_rst,
    input  wire [WR_DATA_WIDTH-1:0] wr_data,
    input  wire                     wr_en,
    output wire                     wr_full,
    output wire                     almost_full,
    output wire [WR_DEPTH_WIDTH:0]  wr_level,

    input  wire                     rd_clk,
    input  wire                     rd_rst,
    output wire [RD_DATA_WIDTH-1:0] rd_data,
    input  wire                     rd_en,
    output wire                     rd_empty,
    output wire                     rd_valid,
    output wire                     almost_empty,
    output wire [RD_DEPTH_WIDTH:0]  rd_level
);
    wire wr_vld;
    wire rd_vld;
    // Both pointers and the prefetch queue must share a reset interval.
    // Independent short VSYNC pulses let the reader briefly synchronize an
    // old write pointer and prefetch stale pixels into the new frame.
    wire fifo_reset = wr_rst || rd_rst;
    reg [2:0] wr_reset_pipe, rd_reset_pipe;
    always @(posedge wr_clk or posedge fifo_reset) begin
        if(fifo_reset)wr_reset_pipe<=3'b111;
        else wr_reset_pipe<={wr_reset_pipe[1:0],1'b0};
    end
    always @(posedge rd_clk or posedge fifo_reset) begin
        if(fifo_reset)rd_reset_pipe<=3'b111;
        else rd_reset_pipe<={rd_reset_pipe[1:0],1'b0};
    end
    assign rd_valid = rd_vld;

    ipm_fifo_v1_4 #(
        .c_WR_DEPTH_WIDTH   (WR_DEPTH_WIDTH),
        .c_WR_DATA_WIDTH    (WR_DATA_WIDTH),
        .c_RD_DEPTH_WIDTH   (RD_DEPTH_WIDTH),
        .c_RD_DATA_WIDTH    (RD_DATA_WIDTH),
        .c_PREFETCH_EN      (1),
        .c_OUTPUT_REG       (0),
        .c_RD_OCE_EN        (0),
        .c_RESET_TYPE       ("ASYNC_RESET"),
        .c_POWER_OPT        (1),
        .c_WR_BYTE_EN       (0),
        .c_BE_WIDTH         (1),
        .c_FIFO_TYPE        ("ASYN"),
        .c_ALMOST_FULL_NUM  (ALMOST_FULL),
        .c_ALMOST_EMPTY_NUM (ALMOST_EMPTY)
    ) u_fifo (
        .wr_data        (wr_data),
        .wr_en          (wr_en && !wr_full && !wr_reset_pipe[2]),
        .wr_vld         (wr_vld),
        .wr_clk         (wr_clk),
        .wr_full        (wr_full),
        .wr_rst         (wr_reset_pipe[2]),
        .wr_byte_en     (1'b1),
        .almost_full    (almost_full),
        .wr_water_level (wr_level),
        .rd_data        (rd_data),
        // Prefetch keeps up to two valid words outside the RAM. Its RAM-empty
        // flag can be high while those words still need to be consumed.
        .rd_en          (rd_en && rd_vld && !rd_reset_pipe[2]),
        .rd_vld         (rd_vld),
        .rd_clk         (rd_clk),
        .rd_empty       (rd_empty),
        .rd_rst         (rd_reset_pipe[2]),
        .rd_oce         (1'b1),
        .almost_empty   (almost_empty),
        .rd_water_level (rd_level)
    );
endmodule
