`timescale 1ns/1ps
// Two 128x16 stripes. Scatter tile results, then emit eight-beat row bursts.
module pipeline_stripe_writer(
 input wire clock,reset_n,frame_start_i,abort_i,
 input wire [27:0] frame_base_i,input wire [9:0] stride_words_i,
 input wire tile_start_i,input wire [10:0] tile_x_i,grid_y_i,input wire [4:0] grid_height_i,
 output wire tile_ready_o,
 input wire pixel_valid_i,input wire [15:0] pixel_i,input wire [10:0] pixel_x_i,pixel_y_i,
 output wire idle_o,output reg error_o,
 output wire [27:0] axi_awaddr,output wire [3:0] axi_awlen,axi_awid,
 output wire axi_awvalid,input wire axi_awready,
 output wire [255:0] axi_wdata,output wire [31:0] axi_wstrb,input wire axi_wready,axi_wlast,
 output wire write_wait_o
);
 reg [1:0] bank_state[0:1]; // 0 free, 1 filling, 2 ready, 3 writing
 reg fill_bank,write_bank,fill_active;
 reg [10:0] bx[0:1],by[0:1];reg [4:0] bh[0:1];
 reg [11:0] fill_count;reg [27:0] base;reg [9:0] stride;
 reg [2:0] state;reg [4:0] row;reg [2:0] beat;
 reg [27:0] write_address;
 reg aw_pending;
 wire same_stripe=bx[fill_bank]=={tile_x_i[10:7],7'd0}&&by[fill_bank]==grid_y_i&&bh[fill_bank]==grid_height_i;
 assign tile_ready_o=!abort_i&&(fill_active?same_stripe:bank_state[fill_bank]==0);
 wire [11:0] dx={1'b0,pixel_x_i}-{1'b0,bx[fill_bank]},dy={1'b0,pixel_y_i}-{1'b0,by[fill_bank]};
 wire pixel_inside=fill_active&&dx<128&&dy<bh[fill_bank];
 wire [12:0] wr_addr={1'b0,fill_bank,dy[3:0],dx[6:0]};
 wire [2:0] next_beat=state==3&&axi_wready&&beat<7?beat+1'b1:beat;
 wire [8:0] rd_addr={1'b0,write_bank,row[3:0],next_beat};
 wire [255:0] ram_data;
 ipm2l_sdpram_v1_10_wr_fram_buf #(
  .c_CAS_MODE("36K"),.c_WR_ADDR_WIDTH(13),.c_WR_DATA_WIDTH(16),
  .c_RD_ADDR_WIDTH(9),.c_RD_DATA_WIDTH(256),.c_OUTPUT_REG(0),.c_RESET_TYPE("SYNC")
 ) stripe_ram(
  .wr_addr(wr_addr),.wr_data(pixel_i),.wr_en(pixel_valid_i&&pixel_inside&&!abort_i),
  .wr_clk(clock),.wr_clk_en(1'b1),.wr_rst(!reset_n),.wr_byte_en(8'hff),.wr_addr_strobe(1'b0),
  .rd_addr(rd_addr),.rd_data(ram_data),.rd_clk(clock),.rd_clk_en(1'b1),.rd_rst(!reset_n),
  .rd_oce(1'b1),.rd_addr_strobe(1'b0));
 wire [27:0] address_row=by[write_bank]+row;
 // Only the two supported row strides occur; shifts avoid a variable multiplier.
 wire [27:0] row_offset=stride==640?(address_row<<9)+(address_row<<7):(address_row<<8)+(address_row<<6);
 assign axi_awaddr=write_address;
 assign axi_awlen=7;assign axi_awid=2;assign axi_awvalid=aw_pending;
 assign axi_wdata=ram_data;assign axi_wstrb=32'hffffffff;
 assign write_wait_o=(state==2&&!axi_awready)||(state==3&&!axi_wready);
 assign idle_o=state==0&&!fill_active&&bank_state[0]==0&&bank_state[1]==0;
 always @(posedge clock)begin
  if(!reset_n)begin state<=0;aw_pending<=0;write_address<=0;bank_state[0]<=0;bank_state[1]<=0;fill_bank<=0;write_bank<=0;fill_active<=0;fill_count<=0;error_o<=0;row<=0;beat<=0;end
  else begin
   if(frame_start_i)begin base<=frame_base_i;stride<=stride_words_i;error_o<=0;end
   if(tile_start_i&&tile_ready_o&&!fill_active)begin
    bx[fill_bank]<={tile_x_i[10:7],7'd0};by[fill_bank]<=grid_y_i;bh[fill_bank]<=grid_height_i;
    bank_state[fill_bank]<=1;fill_active<=1;fill_count<=0;
   end
   if(pixel_valid_i&&!abort_i)begin
    if(!pixel_inside)error_o<=1;
    else begin
     fill_count<=fill_count+1'b1;
     if(fill_count+1'b1==({7'd0,bh[fill_bank]}<<7))begin
      bank_state[fill_bank]<=2;fill_active<=0;fill_bank<=~fill_bank;fill_count<=0;
     end
    end
   end
   if(abort_i)begin
    fill_active<=0;
    // Once AWVALID is raised, keep address/valid stable through READY.
    // Abort may then drain one final burst; it never abandons that transaction.
    if(state!=3&&state!=2)begin bank_state[0]<=0;bank_state[1]<=0;state<=0;aw_pending<=0;end
    else bank_state[~write_bank]<=0;
   end
   case(state)
    0:if(!abort_i&&(bank_state[0]==2||bank_state[1]==2))begin
     write_bank<=bank_state[0]==2?1'b0:1'b1;bank_state[bank_state[0]==2?0:1]<=3;row<=0;beat<=0;state<=1;
    end
    1:if(!abort_i)begin write_address<=base+row_offset+(bx[write_bank]>>1);aw_pending<=1;state<=2;end
    2:if(axi_awready)begin aw_pending<=0;state<=3;end
    3:if(axi_wready)begin
     if(axi_wlast!=(beat==7))error_o<=1;
     if(beat==7)begin
      beat<=0;
      if(abort_i||row==bh[write_bank]-1)begin bank_state[write_bank]<=0;state<=0;end
      else begin row<=row+1'b1;state<=1;end
     end else beat<=beat+1'b1;
    end
   endcase
  end
 end
endmodule
