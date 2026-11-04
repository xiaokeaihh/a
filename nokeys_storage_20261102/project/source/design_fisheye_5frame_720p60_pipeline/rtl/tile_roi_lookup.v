`timescale 1ns/1ps

// Source DDR read rectangle for each 128x8 output tile.
// The x span is 16-pixel aligned to 256-bit AXI beats; y is 4-pixel aligned.
module tile_roi_lookup #(
    parameter ROI_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/rect_quad_roi.mem"
) (
    input  wire        clock,
    input  wire        reset_n,
    // Shared calibration-table port. table_select=1 selects tile ROI entries.
    input  wire        cal_write_en_i,
    input  wire        cal_table_select_i,
    input  wire [13:0] cal_write_addr_i,
    input  wire [47:0] cal_write_data_i,
    input  wire        request_valid_i,
    input wire [2:0] view_i,
    input  wire [3:0]  tile_x_i,
    input  wire [6:0]  tile_y_i,
    output reg         roi_valid_o,
    output reg  [10:0] source_x0_o,
    output reg  [10:0] source_y0_o,
    output reg  [7:0]  source_width_o,
    output reg  [7:0]  source_height_o
);
    reg [47:0] roi_memory [0:7199] /* synthesis syn_ramstyle="block_ram" */;
    initial $readmemh(ROI_FILE, roi_memory);

    wire [12:0] index = view_i*13'd900 + tile_y_i*13'd10 + tile_x_i;
    reg [47:0] roi_d1;
    reg valid_d1;
    always @(posedge clock) begin
        if (cal_write_en_i && cal_table_select_i
            && cal_write_addr_i < 14'd7200)
            roi_memory[cal_write_addr_i[12:0]] <= cal_write_data_i;
        roi_d1 <= roi_memory[index];
        valid_d1 <= request_valid_i && tile_x_i < 4'd10 && tile_y_i < 7'd90;
        source_x0_o <= roi_d1[10:0];
        source_y0_o <= roi_d1[26:16];
        source_width_o <= roi_d1[39:32];
        source_height_o <= roi_d1[47:40];
        roi_valid_o <= valid_d1;
        if (!reset_n) begin
            valid_d1 <= 1'b0;
            roi_valid_o <= 1'b0;
        end
    end
endmodule
