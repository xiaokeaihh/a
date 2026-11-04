`timescale 1ns/1ps
// Two row buffers decouple DDR receive from four-pixel cache loading.
module pipeline_prefetch(
 input wire clock,reset_n,start_i,abort_i,
 input wire [27:0] frame_base_i,input wire [10:0] x0_i,y0_i,
 input wire [7:0] width_i,height_i,
 output wire busy_o,output reg done_o,error_o,
 output wire [27:0] axi_araddr,output wire [3:0] axi_arlen,axi_arid,
 output wire axi_arvalid,input wire axi_arready,
 input wire [255:0] axi_rdata,input wire axi_rvalid,axi_rlast,
 output wire write_o,output wire [7:0] write_x_o,output wire [5:0] write_y_o,
 output wire [63:0] write_pixels_o,
 output wire receive_wait_o,output wire drain_active_o
);
 localparam R_IDLE=0,R_ISSUE=1,R_RECEIVE=2;
 reg active;reg [1:0] rs;
 reg [27:0] base;reg [10:0] x0,y0;reg [7:0] height;
 reg [3:0] beats,rx_beat,tx_beat;reg [1:0] tx_group;
 reg [6:0] rx_row,tx_row;reg rx_bank,tx_bank;reg tx_active;
 reg [1:0] full;reg [5:0] row_tag[0:1];
 reg [255:0] rows0[0:15],rows1[0:15];
 wire [255:0] current_word=tx_bank?rows1[tx_beat]:rows0[tx_beat];
 wire final_group=tx_group==3&&tx_beat==beats-1;
 assign busy_o=active;
 assign axi_araddr=base+(y0+rx_row)*28'd640+(x0>>1);
 assign axi_arlen=beats-1;assign axi_arid=1;
 assign axi_arvalid=active&&rs==R_ISSUE&&!abort_i;
 assign write_o=active&&tx_active&&!abort_i;
 assign write_x_o={tx_beat,tx_group,2'b00};
 assign write_y_o=row_tag[tx_bank];
 assign write_pixels_o=current_word[tx_group*64+:64];
 assign receive_wait_o=active&&((rs==R_ISSUE&&!axi_arready)||(rs==R_RECEIVE&&!axi_rvalid));
 assign drain_active_o=write_o;
 always @(posedge clock)begin
  if(!reset_n)begin active<=0;rs<=R_IDLE;done_o<=0;error_o<=0;full<=0;tx_active<=0;rx_row<=0;tx_row<=0;end
  else begin
   done_o<=0;
   if(start_i&&!active)begin
    base<=frame_base_i;x0<=x0_i;y0<=y0_i;height<=height_i;beats<=width_i[7:4];
    active<=1;rs<=R_IDLE;rx_row<=0;tx_row<=0;rx_bank<=0;tx_bank<=0;full<=0;tx_active<=0;error_o<=0;
    if(width_i==0||width_i>240||width_i[3:0]!=0||height_i==0||height_i>64||height_i[0]||x0_i[3:0]!=0||y0_i[0])begin active<=0;done_o<=1;error_o<=1;end
   end else if(active)begin
    if(abort_i)begin
     tx_active<=0;full<=0;
     if(rs!=R_RECEIVE)begin rs<=R_IDLE;active<=0;done_o<=1;end
    end
    case(rs)
     R_IDLE:if(!abort_i&&rx_row<height&&!full[rx_bank])begin rs<=R_ISSUE;end
     R_ISSUE:if(!abort_i&&axi_arready)begin rs<=R_RECEIVE;rx_beat<=0;row_tag[rx_bank]<=rx_row[5:0];end
     R_RECEIVE:if(axi_rvalid)begin
      if(rx_bank)rows1[rx_beat]<=axi_rdata;else rows0[rx_beat]<=axi_rdata;
      if(axi_rlast!=(rx_beat==beats-1))error_o<=1;
      if(rx_beat==beats-1)begin
       rs<=R_IDLE;
       if(abort_i)begin active<=0;done_o<=1;end
       else begin full[rx_bank]<=1;rx_row<=rx_row+1'b1;rx_bank<=~rx_bank;end
      end else rx_beat<=rx_beat+1'b1;
     end
    endcase
    if(!abort_i)begin
     if(!tx_active&&full[tx_bank])begin tx_active<=1;tx_beat<=0;tx_group<=0;end
     else if(tx_active)begin
      if(final_group)begin
       full[tx_bank]<=0;tx_active<=0;tx_bank<=~tx_bank;tx_row<=tx_row+1'b1;
       if(tx_row==height-1)begin active<=0;done_o<=1;end
      end else if(tx_group==3)begin tx_group<=0;tx_beat<=tx_beat+1'b1;end
      else tx_group<=tx_group+1'b1;
     end
    end
   end
  end
 end
endmodule
