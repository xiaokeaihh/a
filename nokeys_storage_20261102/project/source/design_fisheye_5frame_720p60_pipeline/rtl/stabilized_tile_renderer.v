`timescale 1ns/1ps
// Exact dynamic ROI from every pixel, with recursive subdivision and masked
// partial-beat writes. Invalid rays never abort an otherwise complete frame.
module stabilized_tile_renderer(
 input wire clock,reset_n,start_i,
 input wire [1:0] source_bank_i,destination_bank_i,
 input wire [287:0] matrix_i,
 input wire [2:0] view_i,input wire [1439:0] views_i,
 output wire busy_o,output reg done_o,error_o,
 output wire [27:0] axi_araddr,axi_awaddr,
 output wire [3:0] axi_arlen,axi_arid,axi_awlen,axi_awid,
 output wire axi_arvalid,axi_awvalid,
 input wire axi_arready,axi_awready,
 input wire [255:0] axi_rdata,input wire axi_rvalid,axi_rlast,
 output wire [255:0] axi_wdata,output wire [31:0] axi_wstrb,
 input wire axi_wready,axi_wlast
);
 localparam IDLE=0,INIT=1,CALC=2,DRAIN=3,ROI=4,PF_START=5,PF_WAIT=6,
            ROW_START=7,ISSUE=8,ROW_WAIT=9,NEXT=10,BOUNDS=11,AREA=12;
 reg [3:0] state;
 reg [1:0] src,dst;
 reg [287:0] matrix,baseline_matrix;reg [1439:0] views;reg [2:0] frame_view;
 reg [4:0] grid_height;
 reg [10:0] grid_x,grid_y,tile_x,tile_y;
 reg [4:0] tile_w,tile_h,ic,ir,row,col;
 reg [8:0] received;
 wire [8:0] total=tile_w*tile_h;
 wire [8:0] coordinate_read_address={4'd0,row}*{4'd0,tile_w}+{4'd0,col};
 reg [40:0] coordinates [0:255] /* synthesis syn_ramstyle="block_ram" */;
 reg [40:0] coord;
 reg coord_valid;
 reg any_inside;
 reg [10:0] min_x,min_y,max_x,max_y;
 reg [10:0] roi_x,roi_y;
 reg [7:0] roi_w,roi_h;
 reg [11:0] roi_width_wide,roi_height_wide;
 reg [23:0] roi_area;
 wire [11:0] bx0={1'b0,min_x[10:4],4'd0};
 wire [11:0] by0={1'b0,min_y[10:1],1'b0};
 wire [11:0] bx1=({1'b0,max_x}+12'd17)&12'hff0;
 wire [11:0] by1=({1'b0,max_y}+12'd3)&12'hffe;
 wire [11:0] bw=bx1-bx0,bh=by1-by0;
 wire [23:0] area=bw*bh;
 reg [10:0] stack_x[0:7],stack_y[0:7];
 reg [4:0] stack_w[0:7],stack_h[0:7];
 reg [3:0] sp;
 wire pv,pi;
 wire [19:0] px,py;
 wire active_reset=reset_n&&state!=IDLE;
 wire [10:0] canvas_x=tile_x+ic,canvas_y=tile_y+ir;
 wire single_view=frame_view<5||frame_view==6;
 wire viewport=canvas_x>=320&&canvas_x<960&&canvas_y>=180&&canvas_y<540;
 wire [10:0] local_x=frame_view==5?(canvas_x>=640?canvas_x-11'd640:canvas_x):single_view?(viewport?canvas_x-11'd320:11'd0):canvas_x;
 wire [10:0] local_y=frame_view==5?(canvas_y>=360?canvas_y-11'd360:canvas_y):single_view?(viewport?canvas_y-11'd180:11'd0):canvas_y;
 function [4:0] height_at;input [10:0] y;input [2:0] view;
  begin if(view==5&&y<360&&y+16>360)height_at=360-y;
   else if(y+16>720)height_at=720-y;else height_at=16;end
 endfunction
 assign busy_o=state!=IDLE;
 stabilized_projection project(.clock(clock),.reset_n(active_reset),
  .input_valid_i(state==CALC),.output_x_i(local_x),.output_y_i(local_y),.canvas_valid_i(!single_view||viewport),
  .matrix_i(matrix),.output_valid_o(pv),.inside_o(pi),.source_x_q8_o(px),.source_y_q8_o(py));
 wire pf_done,pf_error,pf_valid;
 wire [7:0] pf_x;wire [5:0] pf_y;wire [15:0] pf_pixel;
 tile_prefetch prefetch(.clock(clock),.reset_n(active_reset),.start_i(state==PF_START),
  .frame_base_i({7'd0,src,19'd0}),.tile_x0_i(roi_x),.tile_y0_i(roi_y),
  .tile_width_i(roi_w),.tile_height_i(roi_h),.busy_o(),.done_o(pf_done),.error_o(pf_error),
  .axi_araddr(axi_araddr),.axi_arlen(axi_arlen),.axi_arid(axi_arid),.axi_arvalid(axi_arvalid),
  .axi_arready(axi_arready),.axi_rdata(axi_rdata),.axi_rvalid(axi_rvalid),.axi_rlast(axi_rlast),
  .pixel_valid_o(pf_valid),.pixel_x_o(pf_x),.pixel_y_o(pf_y),.pixel_o(pf_pixel));
 wire [43:0] read_x,read_y;
 wire [3:0] cache_valid;
 wire [63:0] cache_pixels;
 wire cache_error;
 genvar bank;
 generate for(bank=0;bank<4;bank=bank+1)begin: request
  assign read_x[bank*11+:11]=coord[18:8]+(coord[8]!=(bank%2));
  assign read_y[bank*11+:11]=coord[38:28]+(coord[28]!=(bank/2));
 end endgenerate
 adaptive_tile_cache #(.BANK_WORDS(2048)) cache(
  .clock(clock),.reset_n(active_reset),.tile_config_valid_i(state==PF_START),
  .tile_x0_i(roi_x),.tile_y0_i(roi_y),.tile_width_i(roi_w),.tile_height_i(roi_h),
  .write_valid_i(pf_valid),.write_x_i(pf_x),.write_y_i(pf_y),.write_pixel_i(pf_pixel),
  .read_valid_i({4{coord_valid&&coord[40]}}),.read_x_flat_i(read_x),.read_y_flat_i(read_y),
  .read_valid_o(cache_valid),.read_pixels_flat_o(cache_pixels),.error_o(cache_error));
 reg [2:0] token,inside_pipe;
 reg [17:0] meta[0:2];
 wire [1:0] origin=meta[2][17:16];
 wire [63:0] ordered={cache_pixels[(origin^2'd3)*16+:16],cache_pixels[(origin^2'd2)*16+:16],
                     cache_pixels[(origin^2'd1)*16+:16],cache_pixels[origin*16+:16]};
 wire pixel_valid;wire [15:0] pixel;
 bilinear_rgb565 interpolation(.clock(clock),.reset_n(active_reset),
  .pixel_valid_i(token[2]),.neighborhood_valid_i(inside_pipe[2]),.source_pixels_flat(ordered),
  .fractional_x(meta[2][7:0]),.fractional_y(meta[2][15:8]),
  .pixel_valid_o(pixel_valid),.corrected_pixel(pixel));
 wire writer_ready,writer_done,writer_error;
 stabilized_row_writer writer(.clock(clock),.reset_n(active_reset),
  .start_i(state==ROW_START&&writer_ready),.pixel_count_i(tile_w),.lane_offset_i(tile_x[3:0]),
  .address_i(28'h0180000+{7'd0,dst,19'd0}+(tile_y+row)*28'd640+{18'd0,tile_x[10:4],3'd0}),
  .ready_o(writer_ready),.done_o(writer_done),.error_o(writer_error),
  .pixel_valid_i(pixel_valid),.pixel_i(pixel),
  .axi_awaddr(axi_awaddr),.axi_awlen(axi_awlen),.axi_awid(axi_awid),.axi_awvalid(axi_awvalid),
  .axi_awready(axi_awready),.axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),
  .axi_wready(axi_wready),.axi_wlast(axi_wlast));
 always @(posedge clock)begin
  if(state==ISSUE)coord<=coordinates[coordinate_read_address[7:0]];
  if(!active_reset)begin coord_valid<=0;token<=0;inside_pipe<=0;end
  else begin
   coord_valid<=state==ISSUE;
   token<={token[1:0],coord_valid};inside_pipe<={inside_pipe[1:0],coord[40]};
   meta[0]<={coord[28],coord[8],coord[27:20],coord[7:0]};meta[1]<=meta[0];meta[2]<=meta[1];
  end
  if(!reset_n)begin state<=IDLE;done_o<=0;error_o<=0;sp<=0;end
  else begin
   done_o<=0;
   if(state!=IDLE&&(pf_error||cache_error||writer_error))begin
    state<=IDLE;done_o<=1;error_o<=1;
   end else case(state)
    IDLE:if(start_i)begin
     src<=source_bank_i;dst<=destination_bank_i;baseline_matrix<=matrix_i;views<=views_i;grid_height<=16;
     case(view_i)1,2,3,4,5,6:frame_view<=view_i;default:frame_view<=7;endcase
     grid_x<=0;grid_y<=0;tile_x<=0;tile_y<=0;tile_w<=16;tile_h<=16;sp<=0;
     error_o<=0;state<=INIT;
    end
    INIT:begin
     case(frame_view)
      1:matrix<=views[0+:288];2:matrix<=views[288+:288];
      3:matrix<=views[576+:288];4:matrix<=views[864+:288];6:matrix<=views[1152+:288];
      5:case({tile_y>=360,tile_x>=640})
       2'b00:matrix<=views[576+:288];2'b01:matrix<=views[864+:288];
       2'b10:matrix<=views[0+:288];2'b11:matrix<=views[288+:288];
      endcase
      default:matrix<=baseline_matrix;
     endcase
     ic<=0;ir<=0;received<=0;any_inside<=0;
     min_x<=1279;min_y<=719;max_x<=0;max_y<=0;state<=CALC;
    end
    CALC:begin
     if(ic==tile_w-1)begin ic<=0;if(ir==tile_h-1)state<=DRAIN;else ir<=ir+1'b1;end
     else ic<=ic+1'b1;
    end
    DRAIN:if(pv&&received==total-1)state<=BOUNDS;
    BOUNDS:begin
     roi_x<=bx0[10:0];roi_y<=by0[10:0];roi_width_wide<=bw;roi_height_wide<=bh;state<=AREA;
    end
    AREA:begin roi_area<=roi_width_wide*roi_height_wide;state<=ROI;end
    ROI:begin
     if(any_inside&&(roi_width_wide>240||roi_height_wide>64||roi_area>8192))begin
      if(sp>=8||(tile_w==1&&tile_h==1))begin state<=IDLE;done_o<=1;error_o<=1;end
      else begin
       stack_x[sp]<=tile_x;stack_y[sp]<=tile_y;stack_w[sp]<=tile_w;stack_h[sp]<=tile_h;
       if(tile_w>1&&(roi_width_wide>240||tile_h==1||(roi_area>8192&&tile_w>=tile_h)))begin
        stack_x[sp]<=tile_x+(tile_w>>1);stack_w[sp]<=tile_w>>1;tile_w<=tile_w>>1;
       end else begin stack_y[sp]<=tile_y+(tile_h>>1);stack_h[sp]<=tile_h>>1;tile_h<=tile_h>>1;end
       sp<=sp+1'b1;state<=INIT;
      end
     end else begin
      roi_w<=roi_width_wide[7:0];roi_h<=roi_height_wide[7:0];row<=0;
      state<=any_inside?PF_START:ROW_START;
     end
    end
    PF_START:state<=PF_WAIT;
    PF_WAIT:if(pf_done)state<=ROW_START;
    ROW_START:if(writer_ready)begin col<=0;state<=ISSUE;end
    ISSUE:if(col==tile_w-1)state<=ROW_WAIT;else col<=col+1'b1;
    ROW_WAIT:if(writer_done)begin
     if(row==tile_h-1)state<=NEXT;else begin row<=row+1'b1;state<=ROW_START;end
    end
    NEXT:begin
     if(sp!=0)begin
      tile_x<=stack_x[sp-1'b1];tile_y<=stack_y[sp-1'b1];
      tile_w<=stack_w[sp-1'b1];tile_h<=stack_h[sp-1'b1];sp<=sp-1'b1;state<=INIT;
     end else if(grid_x==1264&&grid_y+grid_height==720)begin state<=IDLE;done_o<=1;end
     else begin
      if(grid_x==1264)begin grid_x<=0;tile_x<=0;grid_y<=grid_y+grid_height;tile_y<=grid_y+grid_height;
       grid_height<=height_at(grid_y+grid_height,frame_view);tile_h<=height_at(grid_y+grid_height,frame_view);end
      else begin grid_x<=grid_x+16;tile_x<=grid_x+16;tile_y<=grid_y;tile_h<=grid_height;end
      tile_w<=16;state<=INIT;
     end
    end
    default:state<=IDLE;
   endcase
   if((state==CALC||state==DRAIN)&&pv)begin
    coordinates[received[7:0]]<={pi,py,px};received<=received+1'b1;
    if(pi)begin
     any_inside<=1;
     if(px[18:8]<min_x)min_x<=px[18:8];if(px[18:8]>max_x)max_x<=px[18:8];
     if(py[18:8]<min_y)min_y<=py[18:8];if(py[18:8]>max_y)max_y<=py[18:8];
    end
   end
  end
 end
endmodule

module stabilized_row_writer(
 input wire clock,reset_n,start_i,
 input wire [4:0] pixel_count_i,input wire [3:0] lane_offset_i,
 input wire [27:0] address_i,
 output wire ready_o,output reg done_o,error_o,
 input wire pixel_valid_i,input wire [15:0] pixel_i,
 output reg [27:0] axi_awaddr,output wire [3:0] axi_awlen,axi_awid,
 output wire axi_awvalid,input wire axi_awready,
 output reg [255:0] axi_wdata,output reg [31:0] axi_wstrb,
 input wire axi_wready,axi_wlast
);
 reg [1:0] state;
 reg [4:0] count,total;reg [3:0] offset;
 wire [4:0] lane={1'b0,offset}+count;
 assign ready_o=state==0;assign axi_awlen=0;assign axi_awid=2;assign axi_awvalid=state==2;
 always @(posedge clock)begin
  if(!reset_n)begin state<=0;done_o<=0;error_o<=0;axi_wdata<=0;axi_wstrb<=0;end
  else begin
   done_o<=0;
   if(pixel_valid_i&&state!=1)error_o<=1;
   case(state)
    0:if(start_i)begin
     if(address_i[2:0]!=0||pixel_count_i==0||pixel_count_i+lane_offset_i>16)error_o<=1;
     else begin state<=1;count<=0;total<=pixel_count_i;offset<=lane_offset_i;axi_awaddr<=address_i;axi_wdata<=0;axi_wstrb<=0;end
    end
    1:if(pixel_valid_i)begin
     axi_wdata[lane*16+:16]<=pixel_i;axi_wstrb[lane*2+:2]<=2'b11;
     if(count==total-1)state<=2;else count<=count+1'b1;
    end
    2:if(axi_awready)state<=3;
    3:if(axi_wready)begin if(!axi_wlast)error_o<=1;state<=0;done_o<=1;end
   endcase
  end
 end
endmodule
