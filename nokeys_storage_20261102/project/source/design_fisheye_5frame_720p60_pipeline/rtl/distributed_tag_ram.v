`timescale 1ns/1ps

// Exact 128 x 35 simple-dual-port storage. Output-stage mode preserves
// read-before-write. Address-stage mode is only for the pool protocol:
// tags stay unchanged during lookup, while same-address PLRU is forwarded.
module distributed_tag_ram #(
 parameter REGISTER_READ_ADDRESS=0,
 parameter SPLIT_TAG_WRITES=0,
 parameter integer SET_BITS=7,
 parameter integer TAG_BITS=8,
 parameter integer WORD_BITS=4*TAG_BITS+3
)(
 input wire clock,read_enable,write_enable,write_tags,
 input wire [SET_BITS-1:0] read_address,write_address,
 input wire [WORD_BITS-1:0] write_data,
 output reg [WORD_BITS-1:0] read_data
);
 localparam integer SEGMENTS=1<<(SET_BITS-5);
 localparam integer LANES=(WORD_BITS+1)/2;
 wire [LANES*2-1:0] padded_write=write_data;
 wire [LANES*2-1:0] segment_data[0:SEGMENTS-1];
 wire [SET_BITS-1:0] ram_read_address;
 genvar segment,word_bit;
 generate for(segment=0;segment<SEGMENTS;segment=segment+1)begin: depth
  for(word_bit=0;word_bit<LANES;word_bit=word_bit+1)begin: width
   GTP_RAM32X2DP memory(
    .DO(segment_data[segment][word_bit*2+:2]),
    .DI(padded_write[word_bit*2+:2]),
    .RADDR(ram_read_address[4:0]),.WADDR(write_address[4:0]),
    .WCLK(clock),.WE(write_enable&&(write_address>>5)==segment&&
                    (!SPLIT_TAG_WRITES||word_bit>=(4*TAG_BITS)/2||write_tags))
   );
  end
 end endgenerate
 generate if(REGISTER_READ_ADDRESS)begin: address_stage
  reg [SET_BITS-1:0] address_q;
  always @(posedge clock)if(read_enable)address_q<=read_address;
  assign ram_read_address=address_q;
  always @* read_data=segment_data[address_q>>5][WORD_BITS-1:0];
 end else begin: output_stage
  assign ram_read_address=read_address;
  always @(posedge clock)if(read_enable)read_data<=segment_data[read_address>>5][WORD_BITS-1:0];
 end endgenerate
endmodule
