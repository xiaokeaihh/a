`timescale 1ns/1ps
// Binary A5 5A TYPE LENGTH PAYLOAD CRC8(TYPE,LENGTH,PAYLOAD), little endian.
// Bounded pending events; counters expose loss rather than hiding it.
module stabilization_telemetry #(parameter CLK_HZ=27000000)(
 input wire clk,rst_n,enable_i,
 input wire sample_i,input wire [159:0] sample_data_i,
 input wire frame_i,input wire [63:0] frame_data_i,
 input wire [47:0] status_data_i,
 input wire diagnostics_i,input wire [1279:0] diagnostics_data_i,
 input wire controls_capable_i,input wire [63:0] controls_data_i,
 input wire sync_capable_i,input wire [223:0] sync_data_i,
 output wire uart_tx_o,output reg [15:0] dropped_o
);
 function [7:0] crc_byte;input [7:0] crc,data;reg [7:0] a;integer k;
 begin a=crc^data;for(k=0;k<8;k=k+1)a=a[7]?(a<<1)^8'h07:a<<1;crc_byte=a;end endfunction
 reg [159:0] sample_pending,frame_pending;
 reg sample_waiting,frame_waiting,status_waiting,sending;
 reg [31:0] status_timer;reg controls_waiting,sync_waiting;
 reg [1279:0] payload,diagnostics_pending;reg diagnostics_waiting;
 reg [7:0] kind,length,checksum,index;
 reg start;reg [7:0] byte_data;
 wire busy;
 reg [7:0] selected;
 always @*begin
  case(index)
   0:selected=8'ha5;1:selected=8'h5a;2:selected=kind;3:selected=length;
   default: selected=index==length+4 ? checksum : payload[(index-4)*8+:8];
  endcase
 end
 icm42688_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(921600)) tx(
  .clk(clk),.rst_n(rst_n&&enable_i),.start(start),.data(byte_data),.busy(busy),.tx(uart_tx_o));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   sample_waiting<=0;frame_waiting<=0;status_waiting<=0;diagnostics_waiting<=0;sending<=0;
   controls_waiting<=0;sync_waiting<=0;status_timer<=0;start<=0;dropped_o<=0;checksum<=0;index<=0;
  end else if(!enable_i)begin
   sample_waiting<=0;frame_waiting<=0;status_waiting<=0;diagnostics_waiting<=0;sending<=0;controls_waiting<=0;sync_waiting<=0;status_timer<=0;start<=0;
  end else begin
   start<=0;
   if(status_timer==CLK_HZ/10-1)begin status_timer<=0;status_waiting<=1;if(controls_capable_i===1'b1)controls_waiting<=1;if(sync_capable_i===1'b1)sync_waiting<=1;end else status_timer<=status_timer+1'b1;
   if(!sending&&!busy&&!start)begin
    checksum<=0;index<=0;
    if(frame_waiting)begin payload<=frame_pending;kind<=2;length<=8;frame_waiting<=0;sending<=1;end
    else if(sample_waiting)begin payload<=sample_pending;kind<=1;length<=20;sample_waiting<=0;sending<=1;end
    else if(diagnostics_waiting)begin payload<=diagnostics_pending;kind<=4;length<=160;diagnostics_waiting<=0;sending<=1;end
    else if(controls_waiting)begin payload<=controls_data_i;kind<=5;length<=8;controls_waiting<=0;sending<=1;end
    else if(sync_waiting)begin payload<=sync_data_i;kind<=6;length<=28;sync_waiting<=0;sending<=1;end
    else if(status_waiting)begin payload<={96'd0,dropped_o,((status_data_i&48'hf7ffffffffff)|48'he00000000000)};kind<=3;length<=8;status_waiting<=0;sending<=1;end
   end else if(sending&&!busy&&!start)begin
    byte_data<=selected;start<=1;
    if(index>=2&&index<length+4)checksum<=crc_byte(checksum,selected);
    if(index==length+4)sending<=0;else index<=index+1'b1;
   end
   // New events win over draining an old pending event on the same edge.
   if(sample_i)begin
    if(sample_waiting&&!(!sending&&!busy&&!start&&!frame_waiting))dropped_o<=dropped_o+1'b1;
    sample_pending<=sample_data_i;sample_waiting<=1;
   end
   if(diagnostics_i===1'b1)begin diagnostics_pending<=diagnostics_data_i;diagnostics_waiting<=1;end
   if(frame_i)begin
    if(frame_waiting&&!(!sending&&!busy&&!start))dropped_o<=dropped_o+1'b1;
    frame_pending<={96'd0,frame_data_i};frame_waiting<=1;
   end
  end
 end
endmodule
