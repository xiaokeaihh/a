`timescale 1ns/1ps

// Nine clock edges, one output token per input token, including invalid borders.
// Rows/columns are floor-1..floor+2. All coefficient math is generated offline.
module adaptive_rgb565 #(
    parameter PHASE_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/cubic_phase_compact.mem",
    parameter DETAIL_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/detail_gate_q8.mem"
) (
    input wire clock, reset_n,
    input wire pixel_valid_i, neighborhood_valid_i,
    input wire [255:0] source_pixels_flat,
    input wire [7:0] fractional_x, fractional_y,
    input wire [8:0] radial_blend_i,
    output reg pixel_valid_o,
    output reg [15:0] corrected_pixel
);
    reg [32:0] phase_rom [0:255] /* synthesis syn_ramstyle = "block_ram" */;
    reg [8:0] detail_rom [0:127];
    initial $readmemh(PHASE_FILE, phase_rom);
    initial $readmemh(DETAIL_FILE, detail_rom);

    function [5:0] channel;
        input [15:0] pixel;
        input integer component;
        begin
            case (component)
                0: channel = {1'b0,pixel[15:11]};
                1: channel = pixel[10:5];
                default: channel = {1'b0,pixel[4:0]};
            endcase
        end
    endfunction
    // The unused c1 is reconstructed by the unit-sum anchor formula.
    function signed [13:0] coefficient0;
        input [32:0] packed_phase;
        begin coefficient0={{4{packed_phase[9]}},packed_phase[9:0]};end
    endfunction
    function signed [13:0] coefficient2;
        input [32:0] packed_phase;
        begin coefficient2={1'b0,packed_phase[22:10]};end
    endfunction
    function signed [13:0] coefficient3;
        input [32:0] packed_phase;
        begin coefficient3={{4{packed_phase[32]}},packed_phase[32:23]};end
    endfunction
    function [14:0] horizontal_linear;
        input [15:0] first,second;
        input integer component;
        input [7:0] phase;
        reg signed [15:0] value;
        begin
            value=$signed({1'b0,channel(first,component),8'd0})
                +channel_difference(second,first,component)*$signed({1'b0,phase});
            horizontal_linear=value[14:0];
        end
    endfunction
    function [22:0] vertical_linear;
        input [14:0] top,bottom;
        input [7:0] phase;
        reg signed [15:0] difference;
        reg signed [24:0] value;
        begin
            difference=$signed({1'b0,bottom})-$signed({1'b0,top});
            value=$signed({1'b0,top,8'd0})+difference*$signed({1'b0,phase});
            vertical_linear=value[22:0];
        end
    endfunction
    function signed [6:0] channel_difference;
        input [15:0] pixel, anchor;
        input integer component;
        begin channel_difference = $signed({1'b0,channel(pixel,component)})
                                 - $signed({1'b0,channel(anchor,component)}); end
    endfunction
    function [5:0] min4;
        input [5:0] a,b,c,d;
        reg [5:0] ab,cd;
        begin ab=a<b?a:b;cd=c<d?c:d;min4=ab<cd?ab:cd;end
    endfunction
    function [5:0] max4;
        input [5:0] a,b,c,d;
        reg [5:0] ab,cd;
        begin ab=a>b?a:b;cd=c>d?c:d;max4=ab>cd?ab:cd;end
    endfunction
    function [9:0] luma_q2;
        input [15:0] pixel;
        begin luma_q2 = {1'b0,pixel[15:11]}*10'd10
                     + pixel[10:5]*10'd9 + {1'b0,pixel[4:0]}*10'd4; end
    endfunction
    function [9:0] luma_min4;
        input [9:0] a,b,c,d;
        reg [9:0] ab,cd;
        begin ab=a<b?a:b;cd=c<d?c:d;luma_min4=ab<cd?ab:cd;end
    endfunction
    function [9:0] luma_max4;
        input [9:0] a,b,c,d;
        reg [9:0] ab,cd;
        begin ab=a>b?a:b;cd=c>d?c:d;luma_max4=ab>cd?ab:cd;end
    endfunction
    wire [15:0] p00 = source_pixels_flat[5*16+:16];
    wire [15:0] p01 = source_pixels_flat[6*16+:16];
    wire [15:0] p10 = source_pixels_flat[9*16+:16];
    wire [15:0] p11 = source_pixels_flat[10*16+:16];
    wire [9:0] luma_max_i = luma_max4(luma_q2(p00),luma_q2(p01),luma_q2(p10),luma_q2(p11));
    wire [9:0] luma_min_i = luma_min4(luma_q2(p00),luma_q2(p01),luma_q2(p10),luma_q2(p11));
    reg [7:0] valid_pipe,inside_pipe;
    reg [8:0] alpha [0:7];
    reg [5:0] lower [0:17],upper [0:17];
    reg [14:0] linear_top0 [0:2],linear_bottom0 [0:2];
    reg [22:0] linear_q16 [0:20];
    reg [7:0] fx0,fy0;
    reg [9:0] luma_max0,luma_min0;
    // Max >= min for every input; the exact Q2 contrast fits ten bits.
    // Move only this subtractor across the existing stage-0 boundary.
    wire [9:0] contrast0 = luma_max0 - luma_min0;
    reg potential0,potential1;
    reg [8:0] gate1;
    reg [255:0] pixels0,pixels1;
    reg [32:0] wx1,wy1,wy2,wy3;
    reg signed [20:0] horizontal_anchor2 [0:11],horizontal_product2 [0:35];
    reg signed [15:0] horizontal_q8_3 [0:11];
    reg signed [31:0] vertical_anchor4 [0:2];
    reg signed [30:0] vertical_product4 [0:8];
    reg signed [32:0] vertical_a5 [0:2],vertical_b5 [0:2];
    reg [25:0] limited_q20_6 [0:2];
    reg signed [37:0] mixed_delta7 [0:2];
    wire [18:0] alpha_product1 = alpha[1]*gate1 + 19'd128;
    wire signed [22:0] horizontal_round2 [0:11];
    wire signed [33:0] vertical_sum5 [0:2];
    wire signed [27:0] mix_difference6 [0:2];
    wire [5:0] result_channel [0:2];
    genvar g;
    generate
        for(g=0;g<12;g=g+1) begin: horizontal_rounding
            assign horizontal_round2[g] =
                ($signed(horizontal_anchor2[g])+$signed(horizontal_product2[g*3]))
                +($signed(horizontal_product2[g*3+1])+$signed(horizontal_product2[g*3+2]))+23'sd8;
        end
        for(g=0;g<3;g=g+1) begin: final_channels
            assign vertical_sum5[g] = $signed(vertical_a5[g]) + $signed(vertical_b5[g]);
            assign mix_difference6[g] = $signed({2'd0,limited_q20_6[g]})
                                      - $signed({1'b0,linear_q16[15+g],4'd0});
            wire signed [38:0] rounded = $signed({4'd0,linear_q16[18+g],12'd0})
                                       + $signed(mixed_delta7[g]) + 39'sd134217728;
            assign result_channel[g] = rounded < 0 ? 6'd0
                : ((rounded >>> 28) > (g==1 ? 63 : 31)) ? (g==1 ? 6'd63 : 6'd31)
                : rounded[33:28];
        end
    endgenerate
    integer c,r,s;
    always @(posedge clock) begin
        // A fixed-delay payload pipe needs no per-pixel CE. Valid/alpha still
        // gate every observable result and all expensive arithmetic. The
        // board's upstream window output is held between valid tokens.
        pixels0 <= source_pixels_flat;
        pixels1 <= pixels0;
        if (pixel_valid_i) begin
            alpha[0] <= radial_blend_i;
            fx0 <= fractional_x; fy0 <= fractional_y;
            luma_max0 <= luma_max_i;
            luma_min0 <= luma_min_i;
            // Eligibility is metadata, not a wide data-bank clock enable.
            potential0 <= neighborhood_valid_i && radial_blend_i != 0;
            for(c=0;c<3;c=c+1) begin
                lower[c] <= min4(channel(p00,c),channel(p01,c),channel(p10,c),channel(p11,c));
                upper[c] <= max4(channel(p00,c),channel(p01,c),channel(p10,c),channel(p11,c));
                linear_top0[c] <= horizontal_linear(p00,p01,c,fractional_x);
                linear_bottom0[c] <= horizontal_linear(p10,p11,c,fractional_x);
            end
        end
        if(valid_pipe[0]) begin
            alpha[1] <= alpha[0]; potential1 <= potential0 && contrast0 > 48;
            gate1 <= detail_rom[contrast0>=127 ? 7'd127 : contrast0[6:0]];
            if(potential0 && contrast0 > 48) begin wx1<=phase_rom[fx0];wy1<=phase_rom[fy0];end
            for(c=0;c<3;c=c+1)
                linear_q16[c] <= vertical_linear(linear_top0[c],linear_bottom0[c],fy0);
        end
        if(valid_pipe[1]) begin
            alpha[2] <= potential1 ? alpha_product1[16:8] : 9'd0;
            if(potential1 && gate1!=0) begin
                wy2<=wy1;
                for(r=0;r<4;r=r+1) for(c=0;c<3;c=c+1) begin
                    horizontal_anchor2[r*3+c] <= $signed({3'd0,channel(pixels1[(r*4+1)*16+:16],c),12'd0});
                    horizontal_product2[(r*3+c)*3] <= channel_difference(pixels1[(r*4)*16+:16],pixels1[(r*4+1)*16+:16],c)*coefficient0(wx1);
                    horizontal_product2[(r*3+c)*3+1] <= channel_difference(pixels1[(r*4+2)*16+:16],pixels1[(r*4+1)*16+:16],c)*coefficient2(wx1);
                    horizontal_product2[(r*3+c)*3+2] <= channel_difference(pixels1[(r*4+3)*16+:16],pixels1[(r*4+1)*16+:16],c)*coefficient3(wx1);
                end
            end
        end
        if(valid_pipe[2] && alpha[2]!=0) begin
            wy3<=wy2;
            for(r=0;r<12;r=r+1) horizontal_q8_3[r] <= horizontal_round2[r] >>> 4;
        end
        if(valid_pipe[3] && alpha[3]!=0) begin
            for(c=0;c<3;c=c+1) begin
                vertical_anchor4[c] <= $signed(horizontal_q8_3[3+c]) <<< 12;
                vertical_product4[c*3] <= ($signed({horizontal_q8_3[c][15],horizontal_q8_3[c]})-$signed({horizontal_q8_3[3+c][15],horizontal_q8_3[3+c]}))*coefficient0(wy3);
                vertical_product4[c*3+1] <= ($signed({horizontal_q8_3[6+c][15],horizontal_q8_3[6+c]})-$signed({horizontal_q8_3[3+c][15],horizontal_q8_3[3+c]}))*coefficient2(wy3);
                vertical_product4[c*3+2] <= ($signed({horizontal_q8_3[9+c][15],horizontal_q8_3[9+c]})-$signed({horizontal_q8_3[3+c][15],horizontal_q8_3[3+c]}))*coefficient3(wy3);
            end
        end
        if(valid_pipe[4] && alpha[4]!=0) begin
            for(c=0;c<3;c=c+1) begin
                vertical_a5[c] <= $signed(vertical_anchor4[c])+$signed(vertical_product4[c*3]);
                vertical_b5[c] <= $signed(vertical_product4[c*3+1])+$signed(vertical_product4[c*3+2]);
            end
        end
        if(valid_pipe[5] && alpha[5]!=0) begin
            for(c=0;c<3;c=c+1) begin
                if(vertical_sum5[c] < $signed({8'd0,lower[15+c],20'd0})) limited_q20_6[c] <= {lower[15+c],20'd0};
                else if(vertical_sum5[c] > $signed({8'd0,upper[15+c],20'd0})) limited_q20_6[c] <= {upper[15+c],20'd0};
                else limited_q20_6[c] <= vertical_sum5[c][25:0];
            end
        end
        if(valid_pipe[6]) for(c=0;c<3;c=c+1)
            mixed_delta7[c] <= alpha[6]!=0 ? mix_difference6[c]*$signed({1'b0,alpha[6]}) : 38'sd0;
        for(s=1;s<6;s=s+1) if(valid_pipe[s-1]) for(c=0;c<3;c=c+1) begin
            lower[s*3+c]<=lower[(s-1)*3+c];upper[s*3+c]<=upper[(s-1)*3+c];
        end
        for(s=2;s<8;s=s+1) if(valid_pipe[s-1]) for(c=0;c<3;c=c+1)
            linear_q16[(s-1)*3+c]<=linear_q16[(s-2)*3+c];
        for(s=3;s<8;s=s+1) if(valid_pipe[s-1]) alpha[s]<=alpha[s-1];
        if(!reset_n) begin valid_pipe<=0;inside_pipe<=0;pixel_valid_o<=0;corrected_pixel<=0;end
        else begin
            valid_pipe<={valid_pipe[6:0],pixel_valid_i};
            inside_pipe<={inside_pipe[6:0],neighborhood_valid_i};
            pixel_valid_o<=valid_pipe[7];
            if(valid_pipe[7]) corrected_pixel<=inside_pipe[7]
                ? {result_channel[0][4:0],result_channel[1],result_channel[2][4:0]} : 16'd0;
        end
    end
endmodule
