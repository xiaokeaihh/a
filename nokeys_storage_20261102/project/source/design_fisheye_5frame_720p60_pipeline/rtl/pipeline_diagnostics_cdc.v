`timescale 1ns/1ps
// Snapshot is held until the receiver acknowledges; never independently sync bits.
module pipeline_diagnostics_cdc #(parameter integer DATA_WIDTH=1280)(
 input wire source_clock,source_reset_n,source_valid_i,input wire [DATA_WIDTH-1:0] source_data_i,
 input wire destination_clock,destination_reset_n,
 output reg destination_valid_o,output reg [DATA_WIDTH-1:0] destination_data_o
);
 reg [DATA_WIDTH-1:0] held;reg send_toggle,ack_toggle;reg [2:0] ack_sync,send_sync;
 always @(posedge source_clock)begin
  if(!source_reset_n)begin send_toggle<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[1:0],ack_toggle};
   if(source_valid_i&&ack_sync[2]==send_toggle)begin held<=source_data_i;send_toggle<=~send_toggle;end
  end
 end
 always @(posedge destination_clock)begin
  if(!destination_reset_n)begin ack_toggle<=0;send_sync<=0;destination_valid_o<=0;destination_data_o<=0;end
  else begin
   send_sync<={send_sync[1:0],send_toggle};destination_valid_o<=0;
   if(send_sync[2]!=ack_toggle)begin destination_data_o<=held;destination_valid_o<=1;ack_toggle<=send_sync[2];end
  end
 end
endmodule
