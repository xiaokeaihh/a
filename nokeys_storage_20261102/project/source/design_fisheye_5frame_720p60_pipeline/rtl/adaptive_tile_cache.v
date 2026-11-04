`timescale 1ns/1ps
// Packed parity banks; five-view renderer configures full 160x64 capacity.
// 2048-word main block RAM plus a 512-word block RAM tail for BANK_WORDS=2560.
// Request register + packed address register + RAM read = three-edge response.
module adaptive_tile_cache #(
    parameter integer BANK_WORDS=2240
) (
    input wire clock,reset_n,tile_config_valid_i,
    input wire [10:0] tile_x0_i,tile_y0_i,
    input wire [7:0] tile_width_i,tile_height_i,
    input wire write_valid_i,
    input wire [7:0] write_x_i,
    input wire [5:0] write_y_i,
    input wire [15:0] write_pixel_i,
    input wire [3:0] read_valid_i,
    input wire [43:0] read_x_flat_i,read_y_flat_i,
    output wire [3:0] read_valid_o,
    output wire [63:0] read_pixels_flat_o,
    output wire error_o
);
    reg [10:0] tile_x0,tile_y0;
    reg [7:0] tile_width,tile_height;
    reg write_error;
    function [11:0] packed_address;
        input [7:0] x;
        input [5:0] y;
        input [6:0] pitch;
        reg [11:0] row,p01,p23,p45,p6;
        begin
            row={7'd0,y[5:1]};
            p01=(pitch[0]?row:12'd0)+(pitch[1]?(row<<1):12'd0);
            p23=(pitch[2]?(row<<2):12'd0)+(pitch[3]?(row<<3):12'd0);
            p45=(pitch[4]?(row<<4):12'd0)+(pitch[5]?(row<<5):12'd0);
            p6=pitch[6]?(row<<6):12'd0;
            packed_address=((p01+p23)+(p45+p6))+{5'd0,x[7:1]};
        end
    endfunction
    wire [6:0] row_pitch=tile_width[7:1]+tile_width[0];
    wire [6:0] configured_pitch=tile_width_i[7:1]+tile_width_i[0];
    wire [11:0] configured_last=packed_address(tile_width_i-8'd1,tile_height_i-8'd1,configured_pitch);
    wire [1:0] write_bank={write_y_i[0],write_x_i[0]};
    wire [11:0] write_address=packed_address(write_x_i,write_y_i,row_pitch);
    wire write_inside=write_x_i<tile_width && write_y_i<tile_height && write_x_i<240 && write_y_i<64 && write_address<BANK_WORDS;
    wire [3:0] bank_error;
    assign error_o=write_error || |bank_error;
    always @(posedge clock) begin
        if(!reset_n) begin tile_x0<=0;tile_y0<=0;tile_width<=0;tile_height<=0;write_error<=0;end
        else begin
            if(tile_config_valid_i) begin
                tile_x0<=tile_x0_i;tile_y0<=tile_y0_i;tile_width<=tile_width_i;tile_height<=tile_height_i;
                if(tile_width_i==0 || tile_height_i==0 || tile_width_i>240 || tile_height_i>64 || tile_x0_i[0] || tile_y0_i[0] || configured_last>=BANK_WORDS) write_error<=1;
            end
            if(write_valid_i && !write_inside) write_error<=1;
        end
    end
    genvar bank;
    generate for(bank=0;bank<4;bank=bank+1) begin: banks
        reg [10:0] x,y;
        reg request0;
        wire [11:0] rx={1'b0,x}-{1'b0,tile_x0},ry={1'b0,y}-{1'b0,tile_y0};
        wire [11:0] address=packed_address(rx[7:0],ry[5:0],row_pitch);
        wire read_in_bounds=x>=tile_x0 && y>=tile_y0 && rx<tile_width && ry<tile_height
                    && x<1280 && y<720 && {ry[0],rx[0]}==bank && address<BANK_WORDS;
        reg [11:0] address0;
        reg valid0,inside0,valid1,inside1,error1;
        wire [15:0] stored_pixel;
        assign read_valid_o[bank]=valid1;
        assign read_pixels_flat_o[bank*16+:16]=inside1 ? stored_pixel:16'd0;
        assign bank_error[bank]=error1;
        if(BANK_WORDS>2048) begin: full_capacity
            reg [15:0] main_pixels [0:2047] /* synthesis syn_ramstyle = "block_ram" */;
            reg [15:0] tail_pixels [0:BANK_WORDS-2049] /* synthesis syn_ramstyle = "block_ram" */;
            reg [15:0] main_read,tail_read;
            reg tail_select;
            assign stored_pixel=tail_select?tail_read:main_read;
            always @(posedge clock) begin
                if(reset_n && write_valid_i && write_inside && write_bank==bank) begin
                    if(write_address[11]) tail_pixels[write_address[10:0]]<=write_pixel_i;
                    else main_pixels[write_address[10:0]]<=write_pixel_i;
                end
                if(valid0) begin
                    tail_select<=address0[11];
                    if(inside0) begin
                        if(address0[11]) tail_read<=tail_pixels[address0[10:0]];
                        else main_read<=main_pixels[address0[10:0]];
                    end
                end
            end
        end else begin: small_capacity
            reg [15:0] pixels [0:BANK_WORDS-1] /* synthesis syn_ramstyle = "block_ram" */;
            reg [15:0] pixel_read;
            assign stored_pixel=pixel_read;
            always @(posedge clock) begin
                if(reset_n && write_valid_i && write_inside && write_bank==bank)
                    pixels[write_address]<=write_pixel_i;
                if(valid0 && inside0) pixel_read<=pixels[address0];
            end
        end
        always @(posedge clock) begin
            if(read_valid_i[bank]) begin x<=read_x_flat_i[bank*11+:11];y<=read_y_flat_i[bank*11+:11];end
            if(request0) begin address0<=read_in_bounds?address:12'd0;inside0<=read_in_bounds;end
            if(valid0) inside1<=inside0;
            if(!reset_n) begin request0<=0;valid0<=0;valid1<=0;inside1<=0;error1<=0;end
            else begin
                request0<=read_valid_i[bank];valid0<=request0;valid1<=valid0;
                if(request0 && !read_in_bounds) error1<=1;
            end
        end
    end endgenerate
endmodule
