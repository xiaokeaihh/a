`timescale 1ns/1ps
`include "source/design_fisheye_5frame_720p60_pipeline/data/radial_constants.vh"

// WYC native K: direct axis tables retain the fractional principal point.
// Seven clock edges, one pixel per clock. All expensive model math is offline.
// Calibration table 0 now contains 17-bit Q1.16 radial gains, NOT 2D anchors.
module remap_original_full #(
    parameter X_RADIUS_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/radial_axis_x.mem",
    parameter Y_RADIUS_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/radial_axis_y.mem",
    parameter EVEN_GAIN_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/radial_gain_even.mem",
    parameter ODD_GAIN_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/radial_gain_odd.mem",
    parameter EVEN_BLEND_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/blend_even.mem",
    parameter ODD_BLEND_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/blend_odd.mem"
) (
    input wire clock, reset_n,
    input wire cal_write_en_i, cal_table_select_i,
    input wire [13:0] cal_write_addr_i,
    input wire [47:0] cal_write_data_i,
    input wire output_valid_i,
    input wire [10:0] output_x, output_y,
    output reg source_valid_o,
    output reg [19:0] source_x_q8, source_y_q8,
    output reg neighborhood_valid_o,
    output reg [8:0] radial_blend_o
);
    reg [17:0] radius_x [0:1279] /* synthesis syn_ramstyle = "block_ram" */;
    reg [17:0] radius_y [0:719] /* synthesis syn_ramstyle = "block_ram" */;
    reg [22:0] valid_spans [0:719];
    initial $readmemh("source/design_fisheye_5frame_720p60_pipeline/data/full_source_spans.mem",valid_spans);
    reg [22:0] span0;
    reg [10:0] output_x0;
    reg inside1,inside2,inside3,inside4,inside5;
    reg [16:0] gain_even [0:512] /* synthesis syn_ramstyle = "block_ram" */;
    reg [16:0] gain_odd [0:512] /* synthesis syn_ramstyle = "block_ram" */;
    reg [8:0] blend_even [0:512] /* synthesis syn_ramstyle = "block_ram" */;
    reg [8:0] blend_odd [0:512] /* synthesis syn_ramstyle = "block_ram" */;
    initial $readmemh(X_RADIUS_FILE, radius_x);
    initial $readmemh(Y_RADIUS_FILE, radius_y);
    initial $readmemh(EVEN_GAIN_FILE, gain_even);
    initial $readmemh(ODD_GAIN_FILE, gain_odd);
    initial $readmemh(EVEN_BLEND_FILE, blend_even);
    initial $readmemh(ODD_BLEND_FILE, blend_odd);

    wire input_in_range = output_x < 1280 && output_y < 720;
    reg [5:0] valid_pipe;
    reg [5:0] range_pipe;
    reg signed [23:0] dx0, dy0, dx1, dy1, dx2, dy2, dx3, dy3, dx4, dy4;
    reg [17:0] radius_x0, radius_y0;
    reg [18:0] radius_sum1;
    wire [10:0] gain_index = radius_sum1[18:8];
    wire [9:0] even_address = {1'b0,gain_index[10:1]} + gain_index[0];
    wire [9:0] odd_address = {1'b0,gain_index[10:1]};
    reg [16:0] even2, odd2;
    reg index_odd2;
    reg [8:0] blend_even2,blend_odd2,blend_origin3,blend4,blend5;
    wire [8:0] blend_origin2=index_odd2 ? blend_odd2:blend_even2;
    wire [8:0] blend_neighbor2=index_odd2 ? blend_even2:blend_odd2;
    wire signed [9:0] blend_difference2=$signed({1'b0,blend_neighbor2})-$signed({1'b0,blend_origin2});
    reg signed [18:0] blend_delta3;
    wire signed [19:0] blend_sum3=$signed({3'd0,blend_origin3,8'd0})+blend_delta3+20'sd128;
    reg [7:0] fraction2;
    wire [16:0] gain_origin2 = index_odd2 ? odd2 : even2;
    wire [16:0] gain_neighbor2 = index_odd2 ? even2 : odd2;
    wire signed [17:0] gain_difference2 = $signed({1'b0,gain_neighbor2}) - $signed({1'b0,gain_origin2});
    reg [16:0] gain_origin3;
    reg signed [26:0] gain_delta3;
    wire signed [27:0] gain_sum3 = $signed({3'd0,gain_origin3,8'd0}) + gain_delta3 + 28'sd128;
    reg [16:0] gain4;
    reg signed [41:0] x_product5, y_product5;
    wire signed [42:0] source_x6 = x_product5 + `FISHEYE_RADIAL_CX_Q28 + 43'sd524288;
    wire signed [42:0] source_y6 = y_product5 + `FISHEYE_RADIAL_CY_Q28 + 43'sd524288;
    wire [19:0] mapped_x6 = source_x6[39:20];
    wire [19:0] mapped_y6 = source_y6[39:20];

    always @(posedge clock) begin
        if (cal_write_en_i && !cal_table_select_i && cal_write_addr_i < 1025) begin
            if (cal_write_addr_i[0]) gain_odd[cal_write_addr_i[13:1]] <= cal_write_data_i[16:0];
            else gain_even[cal_write_addr_i[13:1]] <= cal_write_data_i[16:0];
        end
        if (output_valid_i) begin
            radius_x0 <= radius_x[input_in_range ? output_x : 11'd0];
            radius_y0 <= radius_y[input_in_range ? output_y : 11'd0];
            span0 <= valid_spans[input_in_range ? output_y : 11'd0];
            output_x0 <= output_x;
            dx0 <= $signed({1'b0,output_x,12'd0}) - `FISHEYE_OUTPUT_CX_Q12;
            dy0 <= $signed({1'b0,output_y,12'd0}) - `FISHEYE_OUTPUT_CY_Q12;
        end
        if (valid_pipe[0]) begin
            inside1 <= span0[22] && output_x0>=span0[10:0] && output_x0<=span0[21:11];
            radius_sum1 <= {1'b0,radius_x0} + {1'b0,radius_y0};
            dx1 <= dx0; dy1 <= dy0;
        end
        if (valid_pipe[1]) begin
            inside2 <= inside1;
            even2 <= gain_even[even_address];
            odd2 <= gain_odd[odd_address];
            blend_even2<=blend_even[even_address];
            blend_odd2<=blend_odd[odd_address];
            index_odd2 <= gain_index[0];
            fraction2 <= radius_sum1[7:0];
            dx2 <= dx1; dy2 <= dy1;
        end
        if (valid_pipe[2]) begin
            inside3 <= inside2;
            gain_origin3 <= gain_origin2;
            gain_delta3 <= gain_difference2 * $signed({1'b0,fraction2});
            blend_origin3<=blend_origin2;
            blend_delta3<=blend_difference2*$signed({1'b0,fraction2});
            dx3 <= dx2; dy3 <= dy2;
        end
        if (valid_pipe[3]) begin
            inside4 <= inside3;
            gain4 <= gain_sum3[24:8];
            blend4<=blend_sum3[16:8];
            dx4 <= dx3; dy4 <= dy3;
        end
        if (valid_pipe[4]) begin
            inside5 <= inside4;
            x_product5 <= dx4 * $signed({1'b0,gain4});
            y_product5 <= dy4 * $signed({1'b0,gain4});
            blend5<=blend4;
        end
        if (valid_pipe[5]) begin
            source_x_q8 <= mapped_x6;
            source_y_q8 <= mapped_y6;
            radial_blend_o<=blend5;
            neighborhood_valid_o <= range_pipe[5] && inside5 && source_x6 >= 0 && source_y6 >= 0
                && mapped_x6[19:8] < 1279 && mapped_y6[19:8] < 719;
        end
        if (!reset_n) begin
            inside1<=0;inside2<=0;inside3<=0;inside4<=0;inside5<=0;
            valid_pipe <= 6'd0;
            range_pipe <= 6'd0;
            source_valid_o <= 1'b0;
            neighborhood_valid_o <= 1'b0;
            radial_blend_o<=9'd0;
        end else begin
            valid_pipe <= {valid_pipe[4:0],output_valid_i};
            range_pipe <= {range_pipe[4:0],input_in_range};
            source_valid_o <= valid_pipe[5];
        end
    end
endmodule
