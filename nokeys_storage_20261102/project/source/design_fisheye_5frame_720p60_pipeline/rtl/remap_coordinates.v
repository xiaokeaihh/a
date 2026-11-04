`timescale 1ns/1ps

// Converts raster output coordinates to RGB565 fisheye source coordinates.
// Four parity banks hold each anchor once. Every 2x2 neighborhood touches
// one even/even, even/odd, odd/even, and odd/odd bank, so four synchronous
// reads still sustain one output pixel per clock without ROM replication.
module remap_coordinates #(
    parameter ANCHOR_00_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/map_anchor_00.mem",
    parameter ANCHOR_01_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/map_anchor_01.mem",
    parameter ANCHOR_10_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/map_anchor_10.mem",
    parameter ANCHOR_11_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/map_anchor_11.mem",
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720,
    parameter integer ANCHOR_COLUMNS = 81,
    parameter integer ANCHOR_COUNT = 3726
) (
    input  wire        clock,
    input  wire        reset_n,
    input  wire        cal_write_en_i,
    input  wire        cal_table_select_i,
    input  wire [13:0] cal_write_addr_i,
    input  wire [47:0] cal_write_data_i,
    input  wire        output_valid_i,
    input  wire [10:0] output_x,
    input  wire [10:0] output_y,
    output reg         source_valid_o,
    output reg  [19:0] source_x_q8,
    output reg  [19:0] source_y_q8,
    output reg         neighborhood_valid_o
);
    localparam integer ANCHOR_ROWS = ANCHOR_COUNT / ANCHOR_COLUMNS;
    localparam integer BANK_COLUMNS = (ANCHOR_COLUMNS + 1) / 2;
    localparam integer BANK_DEPTH = ((ANCHOR_ROWS + 1) / 2) * BANK_COLUMNS;
    reg [39:0] anchor_00 [0:BANK_DEPTH-1];
    reg [39:0] anchor_01 [0:BANK_DEPTH-1];
    reg [39:0] anchor_10 [0:BANK_DEPTH-1];
    reg [39:0] anchor_11 [0:BANK_DEPTH-1];

    initial $readmemh(ANCHOR_00_FILE, anchor_00);
    initial $readmemh(ANCHOR_01_FILE, anchor_01);
    initial $readmemh(ANCHOR_10_FILE, anchor_10);
    initial $readmemh(ANCHOR_11_FILE, anchor_11);

    reg [22:0] valid_spans [0:IMAGE_HEIGHT-1];
    initial $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/valid_spans.mem", valid_spans);
    reg [22:0] span_pre0;
    reg [10:0] span_x_pre0;
    reg region_pre1, region_bank_d1, region_d1, region_d2, region_d3, region_d4;

    wire [6:0] anchor_row = output_y[10:4];
    wire [6:0] anchor_column = output_x[10:4];
    reg [9:0] even_row_base_pre0, odd_row_base_pre0;
    reg [5:0] even_column_pre0, odd_column_pre0;
    reg row_parity_pre0, column_parity_pre0;
    reg [3:0] fraction_x_pre0, fraction_y_pre0;
    reg valid_pre0;
    reg [9:0] bank_addr_00_pre1, bank_addr_01_pre1;
    reg [9:0] bank_addr_10_pre1, bank_addr_11_pre1;
    reg row_parity_pre1, column_parity_pre1;
    reg [3:0] fraction_x_pre1, fraction_y_pre1;
    reg valid_pre1;

    reg [39:0] bank_00_d1, bank_01_d1, bank_10_d1, bank_11_d1;
    reg row_parity_d1, column_parity_d1;
    reg [3:0] fraction_x_bank_d1, fraction_y_bank_d1;
    reg valid_bank_d1;

    reg [39:0] top_left_d1;
    reg [39:0] top_right_d1;
    reg [39:0] bottom_left_d1;
    reg [39:0] bottom_right_d1;
    reg [3:0] fraction_x_d1;
    reg [3:0] fraction_y_d1;
    reg valid_d1;

    // Order: top X, bottom X, top Y, bottom Y.
    reg [24:0] horizontal_left_d2 [0:3];
    reg [24:0] horizontal_right_d2 [0:3];
    reg [19:0] horizontal_d3 [0:3];
    reg [24:0] vertical_top_d4 [0:1];
    reg [24:0] vertical_bottom_d4 [0:1];
    reg [3:0] fraction_y_d2, fraction_y_d3;
    reg valid_d2, valid_d3, valid_d4;

    wire [4:0] horizontal_left_weight = 5'd16 - {1'b0, fraction_x_d1};
    wire [4:0] vertical_top_weight = 5'd16 - {1'b0, fraction_y_d3};
    wire [24:0] mixed_x_sum = vertical_top_d4[0] + vertical_bottom_d4[0] + 25'd8;
    wire [24:0] mixed_y_sum = vertical_top_d4[1] + vertical_bottom_d4[1] + 25'd8;
    wire [19:0] mixed_x = mixed_x_sum[23:4];
    wire [19:0] mixed_y = mixed_y_sum[23:4];

    // Legacy write address is a row-major index into map_anchor.mem. Only the
    // selected parity bank is written. The shipped top level ties this port off.
    wire [6:0] cal_row = cal_write_addr_i / ANCHOR_COLUMNS;
    wire [6:0] cal_column = cal_write_addr_i % ANCHOR_COLUMNS;
    wire [9:0] cal_bank_addr = (cal_row[6:1] * BANK_COLUMNS)
                              + {4'd0, cal_column[6:1]};
    wire cal_anchor_write = cal_write_en_i && !cal_table_select_i
                            && cal_write_addr_i < ANCHOR_COUNT;

    always @(posedge clock) begin
        if (cal_anchor_write && !cal_row[0] && !cal_column[0])
            anchor_00[cal_bank_addr] <= cal_write_data_i[39:0];
        if (cal_anchor_write && !cal_row[0] && cal_column[0])
            anchor_01[cal_bank_addr] <= cal_write_data_i[39:0];
        if (cal_anchor_write && cal_row[0] && !cal_column[0])
            anchor_10[cal_bank_addr] <= cal_write_data_i[39:0];
        if (cal_anchor_write && cal_row[0] && cal_column[0])
            anchor_11[cal_bank_addr] <= cal_write_data_i[39:0];

        span_pre0 <= valid_spans[output_y];
        span_x_pre0 <= output_x;
        region_pre1 <= span_pre0[22] && span_x_pre0 >= span_pre0[10:0]
                                   && span_x_pre0 <= span_pre0[21:11];
        region_bank_d1 <= region_pre1;
        region_d1 <= region_bank_d1;
        region_d2 <= region_d1;
        region_d3 <= region_d2;
        region_d4 <= region_d3;
        even_row_base_pre0 <= ((anchor_row + 7'd1) >> 1) * BANK_COLUMNS;
        odd_row_base_pre0 <= (anchor_row >> 1) * BANK_COLUMNS;
        even_column_pre0 <= (anchor_column + 7'd1) >> 1;
        odd_column_pre0 <= anchor_column >> 1;
        row_parity_pre0 <= anchor_row[0];
        column_parity_pre0 <= anchor_column[0];
        fraction_x_pre0 <= output_x[3:0];
        fraction_y_pre0 <= output_y[3:0];
        bank_addr_00_pre1 <= even_row_base_pre0 + {4'd0, even_column_pre0};
        bank_addr_01_pre1 <= even_row_base_pre0 + {4'd0, odd_column_pre0};
        bank_addr_10_pre1 <= odd_row_base_pre0 + {4'd0, even_column_pre0};
        bank_addr_11_pre1 <= odd_row_base_pre0 + {4'd0, odd_column_pre0};
        row_parity_pre1 <= row_parity_pre0;
        column_parity_pre1 <= column_parity_pre0;
        fraction_x_pre1 <= fraction_x_pre0;
        fraction_y_pre1 <= fraction_y_pre0;

        bank_00_d1 <= anchor_00[bank_addr_00_pre1];
        bank_01_d1 <= anchor_01[bank_addr_01_pre1];
        bank_10_d1 <= anchor_10[bank_addr_10_pre1];
        bank_11_d1 <= anchor_11[bank_addr_11_pre1];
        row_parity_d1 <= row_parity_pre1;
        column_parity_d1 <= column_parity_pre1;
        fraction_x_bank_d1 <= fraction_x_pre1;
        fraction_y_bank_d1 <= fraction_y_pre1;

        // A separate reorder register keeps the bank mux out of the
        // interpolation multiply path. It adds one 125 MHz clock (8 ns).
        top_left_d1 <= row_parity_d1
            ? (column_parity_d1 ? bank_11_d1 : bank_10_d1)
            : (column_parity_d1 ? bank_01_d1 : bank_00_d1);
        top_right_d1 <= row_parity_d1
            ? (column_parity_d1 ? bank_10_d1 : bank_11_d1)
            : (column_parity_d1 ? bank_00_d1 : bank_01_d1);
        bottom_left_d1 <= row_parity_d1
            ? (column_parity_d1 ? bank_01_d1 : bank_00_d1)
            : (column_parity_d1 ? bank_11_d1 : bank_10_d1);
        bottom_right_d1 <= row_parity_d1
            ? (column_parity_d1 ? bank_00_d1 : bank_01_d1)
            : (column_parity_d1 ? bank_10_d1 : bank_11_d1);
        fraction_x_d1 <= fraction_x_bank_d1;
        fraction_y_d1 <= fraction_y_bank_d1;

        horizontal_left_d2[0] <= top_left_d1[19:0] * horizontal_left_weight;
        horizontal_right_d2[0] <= top_right_d1[19:0] * fraction_x_d1;
        horizontal_left_d2[1] <= bottom_left_d1[19:0] * horizontal_left_weight;
        horizontal_right_d2[1] <= bottom_right_d1[19:0] * fraction_x_d1;
        horizontal_left_d2[2] <= top_left_d1[39:20] * horizontal_left_weight;
        horizontal_right_d2[2] <= top_right_d1[39:20] * fraction_x_d1;
        horizontal_left_d2[3] <= bottom_left_d1[39:20] * horizontal_left_weight;
        horizontal_right_d2[3] <= bottom_right_d1[39:20] * fraction_x_d1;
        fraction_y_d2 <= fraction_y_d1;

        horizontal_d3[0] <= (horizontal_left_d2[0] + horizontal_right_d2[0] + 25'd8) >> 4;
        horizontal_d3[1] <= (horizontal_left_d2[1] + horizontal_right_d2[1] + 25'd8) >> 4;
        horizontal_d3[2] <= (horizontal_left_d2[2] + horizontal_right_d2[2] + 25'd8) >> 4;
        horizontal_d3[3] <= (horizontal_left_d2[3] + horizontal_right_d2[3] + 25'd8) >> 4;
        fraction_y_d3 <= fraction_y_d2;

        vertical_top_d4[0] <= horizontal_d3[0] * vertical_top_weight;
        vertical_bottom_d4[0] <= horizontal_d3[1] * fraction_y_d3;
        vertical_top_d4[1] <= horizontal_d3[2] * vertical_top_weight;
        vertical_bottom_d4[1] <= horizontal_d3[3] * fraction_y_d3;

        source_x_q8 <= region_d4 ? mixed_x : 20'hfffff;
        source_y_q8 <= region_d4 ? mixed_y : 20'hfffff;
        neighborhood_valid_o <= region_d4 && (mixed_x[19:8] < IMAGE_WIDTH - 1)
                             && (mixed_y[19:8] < IMAGE_HEIGHT - 1);

        if (!reset_n) begin
            region_pre1 <= 1'b0; region_bank_d1 <= 1'b0;
            region_d1 <= 1'b0; region_d2 <= 1'b0;
            region_d3 <= 1'b0; region_d4 <= 1'b0;
            valid_pre0 <= 1'b0;
            valid_pre1 <= 1'b0;
            valid_bank_d1 <= 1'b0;
            valid_d1 <= 1'b0;
            valid_d2 <= 1'b0;
            valid_d3 <= 1'b0;
            valid_d4 <= 1'b0;
            source_valid_o <= 1'b0;
            neighborhood_valid_o <= 1'b0;
        end else begin
            valid_pre0 <= output_valid_i;
            valid_pre1 <= valid_pre0;
            valid_bank_d1 <= valid_pre1;
            valid_d1 <= valid_bank_d1;
            valid_d2 <= valid_d1;
            valid_d3 <= valid_d2;
            valid_d4 <= valid_d3;
            source_valid_o <= valid_d4;
        end
    end
endmodule
