`timescale 1ns/1ps

// One complete source rectangle. Four independent banks provide the 2x2
// neighborhood in one read; a second instance enables ping-pong prefetch.
module bilinear_tile_cache #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720
) (
    input  wire        clock,
    input  wire        reset_n,
    input  wire        tile_config_valid_i,
    input  wire [10:0] tile_x0_i,
    input  wire [10:0] tile_y0_i,
    input  wire [7:0]  tile_width_i,
    input  wire [7:0]  tile_height_i,
    input  wire        write_valid_i,
    input  wire [7:0]  write_x_i,
    input  wire [5:0]  write_y_i,
    input  wire [15:0] write_pixel_i,
    input  wire        read_valid_i,
    input  wire [19:0] source_x_q8_i,
    input  wire [19:0] source_y_q8_i,
    output reg         read_valid_o,
    output reg         neighborhood_valid_o,
    output reg  [63:0] source_pixels_flat_o,
    output reg  [7:0]  fractional_x_o,
    output reg  [7:0]  fractional_y_o
);
    localparam integer BANK_ROW_PIXELS = 80;
    localparam integer BANK_DEPTH = 2240;

    reg [10:0] tile_x0;
    reg [10:0] tile_y0;
    reg [7:0] tile_width;
    reg [7:0] tile_height;

    wire [11:0] source_x = {1'b0, source_x_q8_i[19:8]};
    wire [11:0] source_y = {1'b0, source_y_q8_i[19:8]};
    wire [11:0] relative_x = source_x - {1'b0, tile_x0};
    wire [11:0] relative_y = source_y - {1'b0, tile_y0};
    wire read_in_tile = source_x < IMAGE_WIDTH - 1
                     && source_y < IMAGE_HEIGHT - 1
                     && source_x >= {1'b0, tile_x0}
                     && source_y >= {1'b0, tile_y0}
                     && relative_x + 12'd1 < {4'd0, tile_width}
                     && relative_y + 12'd1 < {4'd0, tile_height};

    wire [1:0] write_bank = {write_y_i[0], write_x_i[0]};
    wire [11:0] write_address =
        (write_y_i[5:1] * BANK_ROW_PIXELS) + write_x_i[7:1];
    wire [15:0] bank_pixels [0:3];

    genvar bank_y;
    genvar bank_x;
    generate
        for (bank_y = 0; bank_y < 2; bank_y = bank_y + 1) begin: rows
            for (bank_x = 0; bank_x < 2; bank_x = bank_x + 1) begin: columns
                localparam [1:0] BANK_ID = bank_y * 2 + bank_x;
                wire x_offset = bank_x - relative_x[0];
                wire y_offset = bank_y - relative_y[0];
                wire [11:0] bank_read_x = relative_x + {11'd0, x_offset};
                wire [11:0] bank_read_y = relative_y + {11'd0, y_offset};
                wire [11:0] calculated_address =
                    (bank_read_y[5:1] * BANK_ROW_PIXELS) + bank_read_x[7:1];
                wire [11:0] safe_address = read_in_tile
                    ? calculated_address : 12'd0;

                reg [15:0] pixels [0:BANK_DEPTH-1];
                reg [15:0] read_pixel;
                always @(posedge clock) begin
                    if (write_valid_i && write_bank == BANK_ID)
                        pixels[write_address] <= write_pixel_i;
                    read_pixel <= pixels[safe_address];
                end
                assign bank_pixels[BANK_ID] = read_pixel;
            end
        end
    endgenerate

    reg start_x_bank_d1;
    reg start_y_bank_d1;
    reg [7:0] fraction_x_d1;
    reg [7:0] fraction_y_d1;
    reg valid_d1;
    reg inside_d1;
    integer row;
    integer column;
    reg selected_x_bank;
    reg selected_y_bank;

    always @(posedge clock) begin
        start_x_bank_d1 <= relative_x[0];
        start_y_bank_d1 <= relative_y[0];
        fraction_x_d1 <= source_x_q8_i[7:0];
        fraction_y_d1 <= source_y_q8_i[7:0];
        valid_d1 <= read_valid_i;
        inside_d1 <= read_in_tile;

        for (row = 0; row < 2; row = row + 1) begin
            for (column = 0; column < 2; column = column + 1) begin
                selected_x_bank = start_x_bank_d1 + column;
                selected_y_bank = start_y_bank_d1 + row;
                source_pixels_flat_o[(row*2+column)*16 +: 16] <=
                    bank_pixels[{selected_y_bank, selected_x_bank}];
            end
        end
        fractional_x_o <= fraction_x_d1;
        fractional_y_o <= fraction_y_d1;
        read_valid_o <= valid_d1;
        neighborhood_valid_o <= inside_d1;

        if (!reset_n) begin
            tile_x0 <= 11'd0;
            tile_y0 <= 11'd0;
            tile_width <= 8'd0;
            tile_height <= 8'd0;
            valid_d1 <= 1'b0;
            inside_d1 <= 1'b0;
            read_valid_o <= 1'b0;
            neighborhood_valid_o <= 1'b0;
        end else if (tile_config_valid_i) begin
            tile_x0 <= tile_x0_i;
            tile_y0 <= tile_y0_i;
            tile_width <= tile_width_i;
            tile_height <= tile_height_i;
        end
    end
endmodule
