`timescale 1ns/1ps
// Four parity banks, two same-parity RGB565 pixels per 32-bit word.
// Four adjacent source pixels load per cycle; read latency remains three edges.
module pipeline_source_cache(
 input wire clock,reset_n,config_i,
 input wire [10:0] x0_i,y0_i,input wire [7:0] width_i,height_i,
 input wire write_i,input wire [7:0] write_x_i,input wire [5:0] write_y_i,
 input wire [63:0] write_pixels_i,
 input wire [3:0] read_i,input wire [43:0] read_x_i,read_y_i,
 output wire [3:0] valid_o,output wire [63:0] pixels_o,output wire error_o
);
 reg [10:0] x0,y0;reg [7:0] width,height;reg write_error;
 wire [5:0] pitch=width[7:2];
 wire [11:0] wa=(write_y_i>>1)*pitch+(write_x_i>>2);
 wire wi=write_x_i[1:0]==0&&write_x_i+9'd3<width&&write_y_i<height&&wa<1024;
 wire [3:0] errors;
 assign error_o=write_error||(|errors);
 always @(posedge clock)begin
  if(!reset_n)begin x0<=0;y0<=0;width<=0;height<=0;write_error<=0;end
  else begin
   if(config_i)begin
    x0<=x0_i;y0<=y0_i;width<=width_i;height<=height_i;
    if(width_i==0||width_i>240||width_i[3:0]!=0||height_i==0||height_i>64||height_i[0]||x0_i[3:0]!=0||y0_i[0]||width_i*height_i>8192)write_error<=1;
   end
   if(write_i&&!wi)write_error<=1;
  end
 end
 genvar b;
 generate for(b=0;b<4;b=b+1)begin:banks
  reg [31:0] ram[0:1023] /* synthesis syn_ramstyle="block_ram" */;
  reg [10:0] rx0,ry0;reg request0,valid0,valid1,inside0,inside1,half0,half1,error1;
  reg [9:0] addr0;reg [31:0] word1;
  wire [11:0] dx={1'b0,rx0}-{1'b0,x0},dy={1'b0,ry0}-{1'b0,y0};
  wire [11:0] ra=(dy>>1)*pitch+(dx>>2);
  wire ri=rx0>=x0&&ry0>=y0&&dx<width&&dy<height&&rx0<1280&&ry0<720&&{dy[0],dx[0]}==b&&ra<1024;
  assign valid_o[b]=valid1;
  assign pixels_o[b*16+:16]=inside1?(half1?word1[31:16]:word1[15:0]):16'd0;
  assign errors[b]=error1;
  always @(posedge clock)begin
   if(reset_n&&write_i&&wi&&write_y_i[0]==b/2)
    ram[wa[9:0]]<=b%2?{write_pixels_i[63:48],write_pixels_i[31:16]}:{write_pixels_i[47:32],write_pixels_i[15:0]};
   if(read_i[b])begin rx0<=read_x_i[b*11+:11];ry0<=read_y_i[b*11+:11];end
   if(request0)begin addr0<=ri?ra[9:0]:10'd0;inside0<=ri;half0<=dx[1];end
   if(valid0)begin inside1<=inside0;half1<=half0;if(inside0)word1<=ram[addr0];end
   if(!reset_n)begin request0<=0;valid0<=0;valid1<=0;inside1<=0;error1<=0;end
   else begin request0<=read_i[b];valid0<=request0;valid1<=valid0;if(request0&&!ri)error1<=1;end
  end
 end endgenerate
endmodule
