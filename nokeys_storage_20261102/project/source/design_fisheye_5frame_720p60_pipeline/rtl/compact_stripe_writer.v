`timescale 1ns/1ps
// Two independently fillable stripe banks, ordered archive, and a two-packet
// queue. Both beats exist before AW; accepted AW/W ownership survives abort.
module compact_stripe_writer #(
 parameter integer STRIPE_ROW_BITS=3,TASK_SLOTS=4
)(
 input wire clock,reset_n,frame_start_i,abort_i,input wire [27:0] frame_base_i,
 input wire [9:0] stride_words_i,input wire [10:0] frame_height_i,input wire reverse_i,
 input wire [TASK_SLOTS*128-1:0] task_descriptors_i,output wire [TASK_SLOTS-1:0] task_space_o,
 input wire tile_start_i,input wire [10:0] tile_x_i,grid_y_i,input wire [4:0] grid_height_i,
 output wire tile_ready_o,input wire pixel_valid_i,input wire [15:0] pixel_i,
 input wire [10:0] pixel_x_i,pixel_y_i,output wire idle_o,output reg error_o,
 output wire [27:0] axi_awaddr,output wire [3:0] axi_awlen,axi_awid,output wire axi_awvalid,
 input wire axi_awready,output wire [255:0] axi_wdata,output wire [31:0] axi_wstrb,
 input wire axi_wready,axi_wlast,output wire write_wait_o,output wire [1:0] activity_o,
 output reg stripe_commit_o,output reg [10:0] stripe_x_o,stripe_y_o,output reg [4:0] stripe_height_o
);
 localparam ROWS=1<<STRIPE_ROW_BITS,AB=STRIPE_ROW_BITS+8;
 reg [1:0] bs[0:1];reg [10:0] bx[0:1],by[0:1];reg [4:0] bh[0:1];reg [7:0] seen[0:1];
 reg tile_active,fill_bank,write_bank,write_active,cancelled,reverse;
 reg [2:0] active_tile;reg [STRIPE_ROW_BITS+4:0] pixel_count;
 reg [10:0] expected_x,expected_y,width,height;reg [27:0] base;reg [9:0] stride;
 wire [10:0] next_x=expected_x==width-128?0:expected_x+128;
 wire [10:0] next_y=expected_x==width-128?(reverse?expected_y-ROWS:expected_y+ROWS):expected_y;
 wire stop=abort_i||(cancelled&&!(frame_start_i&&idle_o&&!abort_i));
 wire [159:0] space_state={expected_x,expected_y,next_x,next_y,bs[0],bs[1],bx[0],bx[1],by[0],by[1],seen[0],seen[1]};
 function space;
  input [10:0] x,y;input [159:0] sensitivity_state;reg [10:0] sx;
  reg [10:0] wx,wy,nx,ny,x0,x1,y0,y1;reg [1:0] b0,b1;reg [7:0] s0,s1;
  begin
   {wx,wy,nx,ny,b0,b1,x0,x1,y0,y1,s0,s1}=sensitivity_state;
   sx={x[10:7],7'd0};
   space=((sx==wx&&y==wy)||(sx==nx&&y==ny))&&
      ((b0==1&&x0==sx&&y0==y&&!s0[x[6:4]])||
       (b1==1&&x1==sx&&y1==y&&!s1[x[6:4]])||
       (b0==0&&!(b1!=0&&x1==sx&&y1==y))||
       (b1==0&&!(b0!=0&&x0==sx&&y0==y)));
  end
 endfunction
 genvar c;
 generate for(c=0;c<TASK_SLOTS;c=c+1)begin: candidate
  assign task_space_o[c]=!stop&&space(task_descriptors_i[c*128+:11],task_descriptors_i[c*128+11+:11],space_state);
 end endgenerate
 wire choose_bank=bs[1]==1&&bx[1]=={tile_x_i[10:7],7'd0}&&by[1]==grid_y_i?1'b1:
                  bs[0]==1&&bx[0]=={tile_x_i[10:7],7'd0}&&by[0]==grid_y_i?1'b0:bs[0]!=0;
 assign tile_ready_o=!stop&&!tile_active&&grid_height_i!=0&&grid_height_i<=ROWS&&space(tile_x_i,grid_y_i,space_state);
 wire [10:0] ex=bx[fill_bank]+{4'd0,active_tile,4'd0}+{7'd0,pixel_count[3:0]};
 wire [10:0] ey=by[fill_bank]+(pixel_count>>4);
 wire pixel_inside=tile_active&&pixel_x_i==ex&&pixel_y_i==ey;
 wire [10:0] dx=pixel_x_i-bx[fill_bank],dy=pixel_y_i-by[fill_bank];
 wire [AB-1:0] wr_addr={fill_bank,dy[STRIPE_ROW_BITS-1:0],dx[6:0]};
 reg [2:0] assemble;reg [1:0] send;
 reg [4:0] row,read_count;reg [1:0] group_id;
 reg read_pending;reg [3:0] read_position;
 reg [1:0] packet_valid;reg packet_head,packet_tail,assembling_packet,beat;
 reg [511:0] packet[0:1];reg [27:0] packet_address[0:1];reg packet_final[0:1];
 wire issue_read=assemble==2&&read_count<16&&!stop;
 wire [AB-2:0] rd_addr={write_bank,row[STRIPE_ROW_BITS-1:0],group_id,read_count[3:0]};
 wire [31:0] rd_data;
 wire [27:0] address_row=by[write_bank]+row;
 wire [27:0] row_offset=stride==640?(address_row<<9)+(address_row<<7):(address_row<<8)+(address_row<<6);
 assign axi_awaddr=packet_address[packet_head];assign axi_awlen=1;assign axi_awid=2;
 assign axi_awvalid=send==1;
 assign axi_wdata=beat?packet[packet_head][511:256]:packet[packet_head][255:0];
 assign axi_wstrb=32'hffffffff;
 assign write_wait_o=(send==1&&!axi_awready)||(send==2&&!axi_wready);
 assign activity_o={assemble==1&&packet_valid[packet_tail],assemble==2||assemble==3};
 assign idle_o=!write_active&&!tile_active&&bs[0]==0&&bs[1]==0&&send==0&&assemble==0&&packet_valid==0;
 wire write_pixel=pixel_valid_i&&pixel_inside&&!stop;
 ipm2l_sdpram_v1_10_wr_fram_buf #(.c_CAS_MODE("36K"),.c_WR_ADDR_WIDTH(AB),.c_WR_DATA_WIDTH(16),
  .c_RD_ADDR_WIDTH(AB-1),.c_RD_DATA_WIDTH(32),.c_OUTPUT_REG(0),.c_WR_CLK_EN(1),.c_RD_CLK_EN(1),.c_RESET_TYPE("SYNC")) memory(
  .wr_addr(wr_addr),.wr_data(pixel_i),.wr_en(write_pixel),.wr_clk(clock),.wr_clk_en(write_pixel),.wr_rst(!reset_n),
  .wr_byte_en(8'hff),.wr_addr_strobe(1'b0),.rd_addr(rd_addr),.rd_data(rd_data),.rd_clk(clock),.rd_clk_en(issue_read),
  .rd_rst(!reset_n),.rd_oce(1'b1),.rd_addr_strobe(1'b0));
 integer lane;
 always @(posedge clock)begin
  if(!reset_n)begin
   bs[0]<=0;bs[1]<=0;seen[0]<=0;seen[1]<=0;tile_active<=0;fill_bank<=0;write_bank<=0;write_active<=0;
   cancelled<=0;error_o<=0;assemble<=0;send<=0;packet_valid<=0;packet_head<=0;packet_tail<=0;
   read_pending<=0;read_count<=0;row<=0;group_id<=0;beat<=0;stripe_commit_o<=0;
   expected_x<=0;expected_y<=0;width<=1280;height<=720;reverse<=0;
  end else begin
   stripe_commit_o<=0;read_pending<=issue_read;if(issue_read)read_position<=read_count[3:0];
   if(read_pending&&!stop)for(lane=0;lane<16;lane=lane+1)
    if(read_position==lane)packet[assembling_packet][lane*32+:32]<=rd_data;
   if(frame_start_i)begin
    if(!idle_o)error_o<=1;
    else begin
     base<=frame_base_i;stride<=stride_words_i;cancelled<=0;error_o<=0;expected_x<=0;
     width<=stride_words_i==320?640:1280;
     height<=((^frame_height_i)===1'bx)?(stride_words_i==320?360:720):frame_height_i;
     reverse<=reverse_i===1'b1;
     expected_y<=reverse_i===1'b1 ? frame_height_i-ROWS:0;
     packet_head<=0;packet_tail<=0;seen[0]<=0;seen[1]<=0;
    end
   end
   if(tile_start_i&&tile_ready_o)begin
    fill_bank<=choose_bank;tile_active<=1;active_tile<=tile_x_i[6:4];pixel_count<=0;
    if(bs[choose_bank]==0)begin
     bs[choose_bank]<=1;bx[choose_bank]<={tile_x_i[10:7],7'd0};by[choose_bank]<=grid_y_i;
     bh[choose_bank]<=grid_height_i;seen[choose_bank]<=0;
    end
   end
   if(pixel_valid_i&&!stop)begin
    if(!pixel_inside)error_o<=1;
    else begin
     pixel_count<=pixel_count+1'b1;
     if(pixel_count+1'b1==({4'd0,bh[fill_bank]}<<4))begin
      tile_active<=0;seen[fill_bank][active_tile]<=1;
      if((seen[fill_bank]|(8'b1<<active_tile))==8'hff)bs[fill_bank]<=2;
     end
    end
   end
   case(assemble)
    0:if(!stop)begin
     if(bs[0]==2&&bx[0]==expected_x&&by[0]==expected_y)begin write_bank<=0;write_active<=1;bs[0]<=3;row<=0;group_id<=0;assemble<=1;end
     else if(bs[1]==2&&bx[1]==expected_x&&by[1]==expected_y)begin write_bank<=1;write_active<=1;bs[1]<=3;row<=0;group_id<=0;assemble<=1;end
    end
    1:if(!stop&&!packet_valid[packet_tail])begin
     assembling_packet<=packet_tail;read_count<=0;assemble<=2;
     packet_address[packet_tail]<=base+row_offset+(bx[write_bank]>>1)+({26'd0,group_id}<<4);
     packet_final[packet_tail]<=row==bh[write_bank]-1&&group_id==3;
    end
    2:if(issue_read)begin read_count<=read_count+1'b1;if(read_count==15)assemble<=3;end
    3:if(!stop&&read_pending&&read_position==15)begin
     packet_valid[assembling_packet]<=1;packet_tail<=~packet_tail;
     if(group_id==3)begin group_id<=0;if(row==bh[write_bank]-1)assemble<=4;else begin row<=row+1'b1;assemble<=1;end end
     else begin group_id<=group_id+1'b1;assemble<=1;end
    end
    4:if(!write_active)assemble<=0;
   endcase
   case(send)
    0:if(!stop&&packet_valid[packet_head])begin beat<=0;send<=1;end
    1:if(axi_awready)send<=2;
    2:if(axi_wready)begin
     if(axi_wlast!=beat)error_o<=1;
     if(beat)begin
      send<=0;beat<=0;packet_valid[packet_head]<=0;packet_head<=~packet_head;
      if(packet_final[packet_head]&&!stop)begin
       stripe_commit_o<=1;stripe_x_o<=bx[write_bank];stripe_y_o<=by[write_bank];stripe_height_o<=bh[write_bank];
       expected_x<=next_x;expected_y<=next_y;bs[write_bank]<=0;write_active<=0;
      end
     end else beat<=1;
    end
   endcase
   if(stop)begin
    cancelled<=1;tile_active<=0;assemble<=0;read_pending<=0;
    if(send==1||send==2)begin
     bs[~write_bank]<=0;packet_valid[~packet_head]<=0;
     if(send==2&&axi_wready&&beat)begin bs[write_bank]<=0;write_active<=0;end
    end else begin bs[0]<=0;bs[1]<=0;packet_valid<=0;write_active<=0;end
   end
  end
 end
endmodule
