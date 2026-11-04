`timescale 1ns/1ps

// Camera pixels -> DDR. Four RGB565 lines of 32-bit packed words cross
// from camera PCLK to the 125 MHz DDR domain through a Gray-pointer FIFO.
module wr_buf #(
    parameter ADDR_WIDTH = 28, ADDR_OFFSET = 0,
    parameter H_NUM = 1280, V_NUM = 720,
    parameter DQ_WIDTH = 32, LEN_WIDTH = 32, PIX_WIDTH = 16,
    parameter LINE_ADDR_WIDTH = 22, FRAME_CNT_WIDTH = 6
) (
    input ddr_clk, input ddr_rstn,
    input wr_clk, input wr_fsync, input wr_en,
    input [PIX_WIDTH-1:0] wr_data,
    input rd_bac, input wire capture_abort_i,
    output reg ddr_wreq,
    output [ADDR_WIDTH-1:0] ddr_waddr,
    output [LEN_WIDTH-1:0] ddr_wr_len,
    input ddr_wrdy, input ddr_wdone,
    output [8*DQ_WIDTH-1:0] ddr_wdata,
    input ddr_wdata_req,
    input [1:0] write_bank,
    output frame_start, output frame_wirq,
    output wire [10:0] committed_lines_o,output wire capture_failed_o,output wire drained_o
);
    localparam integer DDR_WIDTH = 8*DQ_WIDTH;
    localparam integer LINE_BEATS = H_NUM*PIX_WIDTH/DDR_WIDTH;
    localparam integer ADDR_STEP = LINE_BEATS*DDR_WIDTH/DQ_WIDTH;

    reg [1:0] wr_reset_sync;
    always @(posedge wr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) wr_reset_sync <= 2'b00;
        else           wr_reset_sync <= {wr_reset_sync[0], 1'b1};
    end

    reg fsync_d;
    reg frame_toggle;
    reg capture_enable;
    wire input_frame_start = wr_fsync && !fsync_d;
    always @(posedge wr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            fsync_d <= 1'b0;
            frame_toggle <= 1'b0;
            capture_enable <= 1'b0;
        end else begin
            fsync_d <= wr_fsync;
            if (input_frame_start && wr_reset_sync[1]) begin
                frame_toggle <= ~frame_toggle;
                capture_enable <= 1'b1;
            end
        end
    end

    reg [2:0] frame_sync;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) frame_sync <= 3'b000;
        else           frame_sync <= {frame_sync[1:0], frame_toggle};
    end
    wire ddr_frame_edge = frame_sync[2] ^ frame_sync[1];
    reg [3:0] frame_delay;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) frame_delay <= 4'b0000;
        else           frame_delay <= {frame_delay[2:0], ddr_frame_edge};
    end
    assign frame_start = frame_delay[3];

    // Keep the original RGB565 pair order: {odd_pixel, even_pixel}.
    reg [11:0] x_cnt;
    reg [PIX_WIDTH-1:0] pixel_d;
    reg [31:0] packed_data;
    reg packed_valid;
    reg last_pair_pending;
    reg line_toggle;
    reg overflow_latched;
    wire fifo_full, fifo_empty, fifo_valid;
    always @(posedge wr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            x_cnt <= 12'd0;
            pixel_d <= {PIX_WIDTH{1'b0}};
            packed_data <= 32'd0;
            packed_valid <= 1'b0;
            last_pair_pending <= 1'b0;
            line_toggle <= 1'b0;
        end else if (input_frame_start) begin
            x_cnt <= 12'd0;
            packed_valid <= 1'b0;
            last_pair_pending <= 1'b0;
        end else begin
            last_pair_pending <= wr_en && capture_enable && x_cnt == H_NUM-1;
            if (last_pair_pending && !overflow_latched && !fifo_full)
                line_toggle <= ~line_toggle;
            if(wr_en && capture_enable) pixel_d <= wr_data;
            packed_valid <= (PIX_WIDTH == 16) ? (wr_en && x_cnt[0]) : 1'b0;
            if (wr_en && capture_enable) begin
                x_cnt <= (x_cnt == H_NUM-1) ? 12'd0 : x_cnt + 1'b1;
                if (PIX_WIDTH == 16 && x_cnt[0])
                    packed_data <= {wr_data, pixel_d};
            end
        end
    end

    wire [12:0] fifo_wr_level;
    wire [9:0] fifo_rd_level;
    wire [DDR_WIDTH-1:0] fifo_data;
    wire fifo_push = packed_valid && capture_enable;
    video_async_fifo #(
        .WR_DATA_WIDTH(32), .RD_DATA_WIDTH(DDR_WIDTH),
        .WR_DEPTH_WIDTH(12), .RD_DEPTH_WIDTH(9),
        .ALMOST_FULL(3840), .ALMOST_EMPTY(LINE_BEATS)
    ) u_camera_fifo (
        .wr_clk(wr_clk), .wr_rst(!wr_reset_sync[1] || input_frame_start),
        .wr_data(packed_data), .wr_en(fifo_push),
        .wr_full(fifo_full), .almost_full(), .wr_level(fifo_wr_level),
        .rd_clk(ddr_clk), .rd_rst(!ddr_rstn || ddr_frame_edge),
        .rd_data(fifo_data), .rd_en(ddr_wdata_req),
        .rd_empty(fifo_empty), .rd_valid(fifo_valid),
        .almost_empty(), .rd_level(fifo_rd_level)
    );

    // A camera cannot be backpressured. Reject the complete frame if the
    // input FIFO ever fills; never publish a partially captured DDR frame.
    reg overflow_toggle;
    always @(posedge wr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            overflow_latched <= 1'b0;
            overflow_toggle <= 1'b0;
        end else if (input_frame_start) begin
            overflow_latched <= 1'b0;
        end else if (fifo_push && fifo_full && !overflow_latched) begin
            overflow_latched <= 1'b1;
            overflow_toggle <= ~overflow_toggle;
        end
    end
    reg [2:0] overflow_sync;
    reg bad_frame;
    wire overflow_edge = overflow_sync[2] ^ overflow_sync[1];
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            overflow_sync <= 3'b000;
            bad_frame <= 1'b0;
        end else begin
            overflow_sync <= {overflow_sync[1:0], overflow_toggle};
            if (frame_start) bad_frame <= 1'b0;
            else if (overflow_edge) bad_frame <= 1'b1;
        end
    end

    reg [11:0] completed_lines;
    reg [11:0] ready_lines;
    reg [2:0] line_sync;
    wire line_edge = line_sync[2] ^ line_sync[1];
    reg [LINE_ADDR_WIDTH-1:0] address_count;
    reg request_active;
    reg frame_usable;
    wire capture_aborting=(capture_abort_i===1'b1);
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            completed_lines <= 12'd0;
            ready_lines <= 12'd0;
            line_sync <= 3'b000;
            address_count <= {LINE_ADDR_WIDTH{1'b0}};
            request_active <= 1'b0;
            frame_usable <= 1'b0;
            ddr_wreq <= 1'b0;
        end else begin
            ddr_wreq <= 1'b0;
            line_sync <= {line_sync[1:0], line_toggle};
            if (capture_aborting) begin
                // A source switch may follow overflow, an incomplete row or
                // an unusable frame. Do not launch further queued rows, and
                // do not reset an accepted/in-flight DDR transaction.
                frame_usable <= 1'b0;
                if (ddr_wdone && request_active) begin
                    request_active <= 1'b0;
                    completed_lines <= completed_lines + 1'b1;
                    address_count <= address_count + ADDR_STEP;
                end
            end else if (ddr_frame_edge) begin
                frame_usable <= !request_active && ddr_wrdy;
                completed_lines <= 12'd0;
                ready_lines <= 12'd0;
                address_count <= {LINE_ADDR_WIDTH{1'b0}};
                request_active <= 1'b0;
            end else if (ddr_wdone && request_active) begin
                request_active <= 1'b0;
                completed_lines <= completed_lines + 1'b1;
                address_count <= address_count + ADDR_STEP;
            end else if (frame_usable && !request_active && ddr_wrdy &&
                         completed_lines < V_NUM &&
                         ready_lines > completed_lines && fifo_valid) begin
                request_active <= 1'b1;
                ddr_wreq <= 1'b1;
            end
            if (line_edge && !ddr_frame_edge && ready_lines < V_NUM)
                ready_lines <= ready_lines + 1'b1;
        end
    end

    assign ddr_waddr = {write_bank, address_count} + ADDR_OFFSET;
    assign ddr_wr_len = LINE_BEATS;
    assign ddr_wdata = fifo_valid ? fifo_data : {DDR_WIDTH{1'b0}};
    // Publish only after DDR acknowledges the final line. The bank manager
    // then releases this raw write bank; no subsequent request can target it
    // because completed_lines reaches V_NUM on this acknowledgement.
    assign frame_wirq = ddr_wdone && request_active && frame_usable &&
                        (completed_lines == V_NUM-1) &&
                        !bad_frame && !overflow_edge && !ddr_frame_edge && !capture_aborting;
    assign drained_o=!request_active&&!ddr_wreq&&
                     (capture_aborting||(completed_lines>=ready_lines));
    assign committed_lines_o=completed_lines[10:0];
    assign capture_failed_o=bad_frame||overflow_edge||!frame_usable||capture_aborting;
    wire unused_status = fifo_empty | fifo_wr_level[0] | rd_bac;
endmodule
