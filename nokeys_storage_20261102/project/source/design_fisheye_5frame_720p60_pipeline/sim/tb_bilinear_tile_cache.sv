`timescale 1ns/1ps
module tb_bilinear_tile_cache;
    reg clock = 1'b0;
    always #5 clock = ~clock;

    reg reset_n = 1'b0;
    reg tile_config_valid_i = 1'b0;
    reg [10:0] tile_x0_i = 11'd0;
    reg [10:0] tile_y0_i = 11'd0;
    reg [7:0] tile_width_i = 8'd16;
    reg [7:0] tile_height_i = 8'd4;
    reg write_valid_i = 1'b0;
    reg [7:0] write_x_i = 8'd0;
    reg [5:0] write_y_i = 6'd0;
    reg [15:0] write_pixel_i = 16'd0;
    reg read_valid_i = 1'b0;
    reg [19:0] source_x_q8_i = 20'd0;
    reg [19:0] source_y_q8_i = 20'd0;
    wire read_valid_o;
    wire neighborhood_valid_o;
    wire [63:0] source_pixels_flat_o;
    wire [7:0] fractional_x_o;
    wire [7:0] fractional_y_o;

    bilinear_tile_cache dut (
        .clock(clock), .reset_n(reset_n),
        .tile_config_valid_i(tile_config_valid_i),
        .tile_x0_i(tile_x0_i), .tile_y0_i(tile_y0_i),
        .tile_width_i(tile_width_i), .tile_height_i(tile_height_i),
        .write_valid_i(write_valid_i), .write_x_i(write_x_i),
        .write_y_i(write_y_i), .write_pixel_i(write_pixel_i),
        .read_valid_i(read_valid_i), .source_x_q8_i(source_x_q8_i),
        .source_y_q8_i(source_y_q8_i), .read_valid_o(read_valid_o),
        .neighborhood_valid_o(neighborhood_valid_o),
        .source_pixels_flat_o(source_pixels_flat_o),
        .fractional_x_o(fractional_x_o), .fractional_y_o(fractional_y_o)
    );

    task write_pixel;
        input [7:0] x;
        input [5:0] y;
        input [15:0] pixel;
        begin
            @(negedge clock);
            write_x_i = x;
            write_y_i = y;
            write_pixel_i = pixel;
            write_valid_i = 1'b1;
        end
    endtask

    initial begin
        repeat (3) @(negedge clock);
        reset_n = 1'b1;
        tile_config_valid_i = 1'b1;
        @(negedge clock);
        tile_config_valid_i = 1'b0;

        write_pixel(8'd0, 6'd0, 16'hf800);
        write_pixel(8'd1, 6'd0, 16'h07e0);
        write_pixel(8'd0, 6'd1, 16'h001f);
        write_pixel(8'd1, 6'd1, 16'hffff);
        @(negedge clock);
        write_valid_i = 1'b0;

        source_x_q8_i = 20'd128;
        source_y_q8_i = 20'd128;
        read_valid_i = 1'b1;
        @(negedge clock);
        read_valid_i = 1'b0;
        wait (read_valid_o);
        #1;
        if (!neighborhood_valid_o
            || source_pixels_flat_o !== {16'hffff,16'h001f,16'h07e0,16'hf800}
            || fractional_x_o !== 8'd128 || fractional_y_o !== 8'd128)
            $fatal(1, "2x2 cache read mismatch");

        @(negedge clock);
        source_x_q8_i = 20'd491264;
        source_y_q8_i = 20'd0;
        read_valid_i = 1'b1;
        @(negedge clock);
        read_valid_i = 1'b0;
        wait (read_valid_o);
        #1;
        if (neighborhood_valid_o)
            $fatal(1, "right-border neighborhood must be invalid");

        $display("PASS tb_bilinear_tile_cache");
        $finish;
    end
endmodule
