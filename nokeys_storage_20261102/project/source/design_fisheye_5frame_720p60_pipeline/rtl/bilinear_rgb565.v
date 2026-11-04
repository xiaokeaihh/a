`timescale 1ns/1ps

// Two-stage, Q8-fraction bilinear interpolation of a 2x2 RGB565 neighborhood.
// Invalid source coordinates still produce one black output pixel.
module bilinear_rgb565 (
    input  wire        clock,
    input  wire        reset_n,
    input  wire        pixel_valid_i,
    input  wire        neighborhood_valid_i,
    input  wire [63:0] source_pixels_flat,
    input  wire [7:0]  fractional_x,
    input  wire [7:0]  fractional_y,
    output reg         pixel_valid_o,
    output reg  [15:0] corrected_pixel
);
    wire [15:0] top_left = source_pixels_flat[15:0];
    wire [15:0] top_right = source_pixels_flat[31:16];
    wire [15:0] bottom_left = source_pixels_flat[47:32];
    wire [15:0] bottom_right = source_pixels_flat[63:48];

    function [14:0] blend_horizontal;
        input [5:0] left_channel;
        input [5:0] right_channel;
        input [7:0] fraction;
        reg signed [6:0] difference;
        reg signed [15:0] correction;
        begin
            difference = $signed({1'b0,right_channel}) - $signed({1'b0,left_channel});
            correction = difference * $signed({1'b0,fraction});
            blend_horizontal = {left_channel,8'd0} + correction;
        end
    endfunction

    function [5:0] blend_vertical;
        input [14:0] upper_channel;
        input [14:0] lower_channel;
        input [7:0] fraction;
        reg [22:0] weighted;
        reg signed [15:0] difference;
        reg signed [24:0] correction;
        begin
            difference = $signed({1'b0,lower_channel}) - $signed({1'b0,upper_channel});
            correction = difference * $signed({1'b0,fraction});
            // Keep full horizontal precision; round once, exactly as before.
            weighted = {upper_channel,8'd0} + correction + 23'd32768;
            blend_vertical = weighted[21:16];
        end
    endfunction

    reg [14:0] red_top_d1, red_bottom_d1;
    reg [14:0] green_top_d1, green_bottom_d1;
    reg [14:0] blue_top_d1, blue_bottom_d1;
    reg [7:0] fraction_y_d1;
    reg valid_d1;
    reg inside_d1;

    wire [5:0] red_result = blend_vertical(red_top_d1, red_bottom_d1,
                                            fraction_y_d1);
    wire [5:0] green_result = blend_vertical(green_top_d1, green_bottom_d1,
                                              fraction_y_d1);
    wire [5:0] blue_result = blend_vertical(blue_top_d1, blue_bottom_d1,
                                             fraction_y_d1);

    always @(posedge clock) begin
        red_top_d1 <= blend_horizontal({1'b0, top_left[15:11]},
                                       {1'b0, top_right[15:11]}, fractional_x);
        red_bottom_d1 <= blend_horizontal({1'b0, bottom_left[15:11]},
                                          {1'b0, bottom_right[15:11]}, fractional_x);
        green_top_d1 <= blend_horizontal(top_left[10:5],
                                         top_right[10:5], fractional_x);
        green_bottom_d1 <= blend_horizontal(bottom_left[10:5],
                                            bottom_right[10:5], fractional_x);
        blue_top_d1 <= blend_horizontal({1'b0, top_left[4:0]},
                                        {1'b0, top_right[4:0]}, fractional_x);
        blue_bottom_d1 <= blend_horizontal({1'b0, bottom_left[4:0]},
                                           {1'b0, bottom_right[4:0]}, fractional_x);
        fraction_y_d1 <= fractional_y;

        if (!reset_n) begin
            valid_d1 <= 1'b0;
            inside_d1 <= 1'b0;
            pixel_valid_o <= 1'b0;
            corrected_pixel <= 16'd0;
        end else begin
            valid_d1 <= pixel_valid_i;
            inside_d1 <= neighborhood_valid_i;
            pixel_valid_o <= valid_d1;
            corrected_pixel <= inside_d1
                ? {red_result[4:0], green_result, blue_result[4:0]}
                : 16'd0;
        end
    end
endmodule
