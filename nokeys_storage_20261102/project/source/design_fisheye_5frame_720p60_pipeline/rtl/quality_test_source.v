`timescale 1ns/1ps
// The same deterministic frame used by the independent Python and DDR models.
// Camera timing remains live. Select only during VSYNC; never mix a frame.
module quality_test_source(
 input wire clock,reset_n,vsync,de,input wire [15:0] rgb_i,
 input wire request_async,output reg active_o,output wire [15:0] rgb_o
);
 reg request_meta,request_sync;
 reg [19:0] index;
 wire [27:0] product=({8'd0,index}<<8)-({8'd0,index}<<2)-{8'd0,index};
 wire [15:0] pattern=product[15:0]^index[18:3]^16'h5a96;
 assign rgb_o=active_o?pattern:rgb_i;
 always @(posedge clock or negedge reset_n)begin
  if(!reset_n)begin request_meta<=0;request_sync<=0;active_o<=0;index<=0;end
  else begin
   request_meta<=request_async;request_sync<=request_meta;
   if(vsync)begin index<=0;active_o<=request_sync;end
   else if(de)begin
    if(index==20'd921599)index<=0;else index<=index+1'b1;
   end
  end
 end
endmodule
