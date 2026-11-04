`timescale 1ns/1ps
// Three coordinate contexts, two shared source caches and two output stripes.
// Geometry, committed-source prefetch, interpolation and DDR output overlap.
module pipeline_renderer(
 input wire clock,reset_n,start_i,input wire [1:0] source_bank_i,destination_bank_i,
 input wire [2:0] view_i,input wire [287:0] matrix_i,input wire [1439:0] views_i,
 input wire source_complete_i,source_failed_i,input wire [10:0] source_committed_i,
 output wire busy_o,output reg done_o,error_o,
 output wire [27:0] axi_araddr,axi_awaddr,
 output wire [3:0] axi_arlen,axi_arid,axi_awlen,axi_awid,
 output wire axi_arvalid,axi_awvalid,input wire axi_arready,axi_awready,
 input wire [255:0] axi_rdata,input wire axi_rvalid,axi_rlast,
 output wire [255:0] axi_wdata,output wire [31:0] axi_wstrb,input wire axi_wready,axi_wlast,
 output reg [319:0] counters_o
);
 localparam GE_IDLE=0,GE_INIT=1,GE_CALC=2,GE_DRAIN=3,GE_BOUND=4,GE_AREA=5,GE_ROI=6;
 localparam PF_IDLE=0,PF_WATER=1,PF_START=2,PF_WAIT=3;
 localparam PIX_IDLE=0,PIX_ISSUE=1,PIX_DRAIN=2;
 reg running,aborting;reg [1:0] src,dst;reg [2:0] frame_view;
 reg [287:0] baseline,matrix;reg [1439:0] views;
 reg [10:0] output_width,output_height;reg [9:0] stride;
 reg [2:0] gs;reg [1:0] fs,ps;reg g_finished;
 reg [1:0] g_tail,f_head,p_head;
 reg [2:0] slot_state[0:2];reg slot_inside[0:2],slot_cache[0:2];
 reg [10:0] slot_x[0:2],slot_y[0:2],slot_grid_y[0:2];
 reg [4:0] slot_w[0:2],slot_h[0:2],slot_grid_h[0:2];
 reg [8:0] slot_total[0:2];
 reg [10:0] slot_rx[0:2],slot_ry[0:2];reg [7:0] slot_rw[0:2],slot_rh[0:2];
 reg [40:0] coordinates[0:1023] /* synthesis syn_ramstyle="block_ram" */;
 reg [10:0] grid_x,grid_y,tile_x,tile_y;reg [4:0] grid_h,tile_w,tile_h,ic,ir;
 reg [8:0] received;
 reg any_inside;reg [10:0] min_x,min_y,max_x,max_y;
 reg [11:0] roi_wide,roi_high;reg [10:0] roi_x,roi_y;reg [23:0] roi_area;
 reg [10:0] stack_x[0:7],stack_y[0:7];reg [4:0] stack_w[0:7],stack_h[0:7];reg [3:0] sp;
 reg [1:0] cache_busy;reg pf_bank;
 reg [4:0] row,col;reg [8:0] returned;
 wire [8:0] g_total=tile_w*tile_h,p_total=slot_total[p_head];
 wire [11:0] bx0={1'b0,min_x[10:4],4'd0},by0={1'b0,min_y[10:1],1'b0};
 wire [11:0] bx1=({1'b0,max_x}+12'd17)&12'hff0,by1=({1'b0,max_y}+12'd3)&12'hffe;
 function [1:0] advance;input [1:0] n;begin advance=n==2?0:n+1'b1;end endfunction
 function [4:0] height_at;input [10:0] y;input [2:0] v;input [10:0] h;
  begin if(v==5&&y<360&&y+16>360)height_at=360-y;
   else if(y+16>h)height_at=h-y;else height_at=16;end
 endfunction
 wire active_reset=reset_n&&running;
 wire pv,pi;wire [19:0] px,py;
 wire [10:0] gx=frame_view==5?(tile_x+ic>=640?tile_x+ic-11'd640:tile_x+ic):tile_x+ic;
 wire [10:0] gy=frame_view==5?(tile_y+ir>=360?tile_y+ir-11'd360:tile_y+ir):tile_y+ir;
 stabilized_projection projection(.clock(clock),.reset_n(active_reset),
  .input_valid_i(gs==GE_CALC&&!aborting),.output_x_i(gx),.output_y_i(gy),.canvas_valid_i(1'b1),
  .matrix_i(matrix),.output_valid_o(pv),.inside_o(pi),.source_x_q8_o(px),.source_y_q8_o(py));
 wire pf_done,pf_error,pf_write,pf_busy,pf_receive_wait,pf_drain;
 wire [7:0] pf_x;wire [5:0] pf_y;wire [63:0] pf_pixels;
 pipeline_prefetch prefetch(.clock(clock),.reset_n(active_reset),.start_i(fs==PF_START&&!aborting),.abort_i(aborting),
  .frame_base_i({7'd0,src,19'd0}),.x0_i(slot_rx[f_head]),.y0_i(slot_ry[f_head]),
  .width_i(slot_rw[f_head]),.height_i(slot_rh[f_head]),.busy_o(pf_busy),.done_o(pf_done),.error_o(pf_error),
  .axi_araddr(axi_araddr),.axi_arlen(axi_arlen),.axi_arid(axi_arid),.axi_arvalid(axi_arvalid),
  .axi_arready(axi_arready),.axi_rdata(axi_rdata),.axi_rvalid(axi_rvalid),.axi_rlast(axi_rlast),
  .write_o(pf_write),.write_x_o(pf_x),.write_y_o(pf_y),.write_pixels_o(pf_pixels),
  .receive_wait_o(pf_receive_wait),.drain_active_o(pf_drain));
 reg [40:0] coord;reg coord_valid;
 reg [10:0] coord_x,coord_y;
 wire issue_pixel=ps==PIX_ISSUE&&!aborting;
 wire [9:0] coord_addr={p_head,8'd0}+row*slot_w[p_head]+col;
 wire [43:0] read_x,read_y;
 genvar b;
 generate for(b=0;b<4;b=b+1)begin: request
  assign read_x[b*11+:11]=coord[18:8]+(coord[8]!=(b%2));
  assign read_y[b*11+:11]=coord[38:28]+(coord[28]!=(b/2));
 end endgenerate
 wire [3:0] request_valid={4{coord_valid&&coord[40]&&!aborting}};
 wire [3:0] va,vb;wire [63:0] ca,cb;wire ea,eb;
 pipeline_source_cache cache_a(.clock(clock),.reset_n(active_reset),.config_i(fs==PF_START&&!pf_bank),
  .x0_i(slot_rx[f_head]),.y0_i(slot_ry[f_head]),.width_i(slot_rw[f_head]),.height_i(slot_rh[f_head]),
  .write_i(pf_write&&!pf_bank),.write_x_i(pf_x),.write_y_i(pf_y),.write_pixels_i(pf_pixels),
  .read_i(slot_cache[p_head]?4'd0:request_valid),.read_x_i(read_x),.read_y_i(read_y),.valid_o(va),.pixels_o(ca),.error_o(ea));
 pipeline_source_cache cache_b(.clock(clock),.reset_n(active_reset),.config_i(fs==PF_START&&pf_bank),
  .x0_i(slot_rx[f_head]),.y0_i(slot_ry[f_head]),.width_i(slot_rw[f_head]),.height_i(slot_rh[f_head]),
  .write_i(pf_write&&pf_bank),.write_x_i(pf_x),.write_y_i(pf_y),.write_pixels_i(pf_pixels),
  .read_i(slot_cache[p_head]?request_valid:4'd0),.read_x_i(read_x),.read_y_i(read_y),.valid_o(vb),.pixels_o(cb),.error_o(eb));
 wire [63:0] cache_pixels=slot_cache[p_head]?cb:ca;
 reg [2:0] token,inside_pipe;reg [17:0] meta[0:2];reg [21:0] positions[0:4];
 wire [1:0] origin=meta[2][17:16];
 wire [63:0] ordered={cache_pixels[(origin^2'd3)*16+:16],cache_pixels[(origin^2'd2)*16+:16],cache_pixels[(origin^2'd1)*16+:16],cache_pixels[origin*16+:16]};
 wire pixel_valid;wire [15:0] pixel;
 bilinear_rgb565 interpolation(.clock(clock),.reset_n(active_reset),.pixel_valid_i(token[2]),
  .neighborhood_valid_i(inside_pipe[2]),.source_pixels_flat(ordered),.fractional_x(meta[2][7:0]),
  .fractional_y(meta[2][15:8]),.pixel_valid_o(pixel_valid),.corrected_pixel(pixel));
 wire writer_ready,writer_idle,writer_error,write_wait;
 pipeline_stripe_writer writer(.clock(clock),.reset_n(reset_n),.frame_start_i(start_i&&!running),.abort_i(aborting),
  .frame_base_i(28'h0180000+{7'd0,destination_bank_i,19'd0}),
  .stride_words_i((view_i<5||view_i==6)?10'd320:10'd640),
  .tile_start_i(ps==PIX_IDLE&&slot_state[p_head]==3&&writer_ready&&!aborting),
  .tile_x_i(slot_x[p_head]),.grid_y_i(slot_grid_y[p_head]),.grid_height_i(slot_grid_h[p_head]),
  .tile_ready_o(writer_ready),.pixel_valid_i(pixel_valid&&!aborting),.pixel_i(pixel),
  .pixel_x_i(positions[4][10:0]),.pixel_y_i(positions[4][21:11]),.idle_o(writer_idle),.error_o(writer_error),
  .axi_awaddr(axi_awaddr),.axi_awlen(axi_awlen),.axi_awid(axi_awid),.axi_awvalid(axi_awvalid),
  .axi_awready(axi_awready),.axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),.axi_wlast(axi_wlast),.write_wait_o(write_wait));
 assign busy_o=running;
 integer j;
 always @(posedge clock)begin
  if(issue_pixel)begin coord<=coordinates[coord_addr];coord_x<=slot_x[p_head]+col;coord_y<=slot_y[p_head]+row;end
  if(!active_reset)begin coord_valid<=0;token<=0;inside_pipe<=0;end
  else begin
   coord_valid<=issue_pixel;token<={token[1:0],coord_valid};inside_pipe<={inside_pipe[1:0],coord_valid&&coord[40]};
   if(coord_valid)begin meta[0]<={coord[28],coord[8],coord[27:20],coord[7:0]};positions[0]<={coord_y,coord_x};end
   for(j=1;j<3;j=j+1)begin meta[j]<=meta[j-1];positions[j]<=positions[j-1];end
   positions[3]<=positions[2];positions[4]<=positions[3];
  end
 end
 // 0 total,1 geometry,2 geometry slot wait,3 source watermark wait,
 // 4 DDR read wait,5 cache loading,6 pixel-context wait,7 output DDR wait,
 // 8 recursive splits,9 output pixels. All are core-clock counts except 8/9.
 always @(posedge clock)begin
  if(!reset_n||start_i&&!running)counters_o<=0;
  else if(running&&!aborting)begin
   counters_o[0+:32]<=counters_o[0+:32]+1'b1;
   if(gs!=GE_IDLE)counters_o[32+:32]<=counters_o[32+:32]+1'b1;
   if(gs==GE_IDLE&&!g_finished&&slot_state[g_tail]!=0)counters_o[64+:32]<=counters_o[64+:32]+1'b1;
   if(fs==PF_WATER&&!source_complete_i&&source_committed_i<slot_ry[f_head]+slot_rh[f_head])counters_o[96+:32]<=counters_o[96+:32]+1'b1;
   if(pf_receive_wait)counters_o[128+:32]<=counters_o[128+:32]+1'b1;
   if(pf_drain)counters_o[160+:32]<=counters_o[160+:32]+1'b1;
   if(ps==PIX_IDLE&&(!g_finished||slot_state[p_head]!=0))counters_o[192+:32]<=counters_o[192+:32]+1'b1;
   if(write_wait)counters_o[224+:32]<=counters_o[224+:32]+1'b1;
   if(gs==GE_ROI&&any_inside&&(roi_wide>240||roi_high>64||roi_area>8192))counters_o[256+:32]<=counters_o[256+:32]+1'b1;
   if(pixel_valid)counters_o[288+:32]<=counters_o[288+:32]+1'b1;
  end
 end
 always @(posedge clock)begin
  if(!reset_n)begin running<=0;aborting<=0;done_o<=0;error_o<=0;gs<=GE_IDLE;fs<=PF_IDLE;ps<=PIX_IDLE;g_finished<=0;cache_busy<=0;for(j=0;j<3;j=j+1)slot_state[j]<=0;end
  else begin
   done_o<=0;
   if(start_i&&!running)begin
    running<=1;aborting<=0;error_o<=0;src<=source_bank_i;dst<=destination_bank_i;frame_view<=view_i;baseline<=matrix_i;views<=views_i;
    output_width<=(view_i<5||view_i==6)?640:1280;output_height<=(view_i<5||view_i==6)?360:720;stride<=(view_i<5||view_i==6)?320:640;
    gs<=GE_IDLE;fs<=PF_IDLE;ps<=PIX_IDLE;g_finished<=0;g_tail<=0;f_head<=0;p_head<=0;
    grid_x<=0;grid_y<=0;grid_h<=16;tile_x<=0;tile_y<=0;tile_w<=16;tile_h<=16;sp<=0;cache_busy<=0;
    for(j=0;j<3;j=j+1)slot_state[j]<=0;
   end else if(running)begin
    if(source_failed_i||pf_error||ea||eb||writer_error)begin aborting<=1;error_o<=1;end
    if(aborting)begin
     if(!pf_busy&&writer_idle)begin running<=0;done_o<=1;gs<=GE_IDLE;fs<=PF_IDLE;ps<=PIX_IDLE;cache_busy<=0;for(j=0;j<3;j=j+1)slot_state[j]<=0;end
    end else begin
     case(gs)
      GE_IDLE:if(!g_finished&&slot_state[g_tail]==0)begin slot_state[g_tail]<=4;gs<=GE_INIT;end
      GE_INIT:begin
       case(frame_view)
        1:matrix<=views[0+:288];2:matrix<=views[288+:288];3:matrix<=views[576+:288];4:matrix<=views[864+:288];6:matrix<=views[1152+:288];
        5:case({tile_y>=360,tile_x>=640})2'b00:matrix<=views[576+:288];2'b01:matrix<=views[864+:288];2'b10:matrix<=views[0+:288];default:matrix<=views[288+:288];endcase
        default:matrix<=baseline;
       endcase
       ic<=0;ir<=0;received<=0;any_inside<=0;min_x<=1279;min_y<=719;max_x<=0;max_y<=0;gs<=GE_CALC;
      end
      GE_CALC:if(ic==tile_w-1)begin ic<=0;if(ir==tile_h-1)gs<=GE_DRAIN;else ir<=ir+1'b1;end else ic<=ic+1'b1;
      GE_DRAIN:if(pv&&received==g_total-1)gs<=GE_BOUND;
      GE_BOUND:begin roi_x<=bx0[10:0];roi_y<=by0[10:0];roi_wide<=bx1-bx0;roi_high<=by1-by0;gs<=GE_AREA;end
      GE_AREA:begin roi_area<=roi_wide*roi_high;gs<=GE_ROI;end
      GE_ROI:begin
       if(any_inside&&(roi_wide>240||roi_high>64||roi_area>8192))begin
        if(sp>=8||(tile_w==1&&tile_h==1))begin aborting<=1;error_o<=1;end
        else begin
         stack_x[sp]<=tile_x;stack_y[sp]<=tile_y;stack_w[sp]<=tile_w;stack_h[sp]<=tile_h;
         if(tile_w>1&&(roi_wide>240||tile_h==1||(roi_area>8192&&tile_w>=tile_h)))begin stack_x[sp]<=tile_x+(tile_w>>1);stack_w[sp]<=tile_w>>1;tile_w<=tile_w>>1;end
         else begin stack_y[sp]<=tile_y+(tile_h>>1);stack_h[sp]<=tile_h>>1;tile_h<=tile_h>>1;end
         sp<=sp+1'b1;gs<=GE_INIT;
        end
       end else begin
        slot_state[g_tail]<=1;slot_inside[g_tail]<=any_inside;slot_x[g_tail]<=tile_x;slot_y[g_tail]<=tile_y;
        slot_w[g_tail]<=tile_w;slot_h[g_tail]<=tile_h;slot_total[g_tail]<=g_total;slot_grid_y[g_tail]<=grid_y;slot_grid_h[g_tail]<=grid_h;
        slot_rx[g_tail]<=roi_x;slot_ry[g_tail]<=roi_y;slot_rw[g_tail]<=roi_wide[7:0];slot_rh[g_tail]<=roi_high[7:0];
        g_tail<=advance(g_tail);gs<=GE_IDLE;
        if(sp!=0)begin tile_x<=stack_x[sp-1'b1];tile_y<=stack_y[sp-1'b1];tile_w<=stack_w[sp-1'b1];tile_h<=stack_h[sp-1'b1];sp<=sp-1'b1;end
        else if(grid_x==output_width-16&&grid_y+grid_h==output_height)g_finished<=1;
        else begin
         if(grid_x==output_width-16)begin grid_x<=0;tile_x<=0;grid_y<=grid_y+grid_h;tile_y<=grid_y+grid_h;grid_h<=height_at(grid_y+grid_h,frame_view,output_height);tile_h<=height_at(grid_y+grid_h,frame_view,output_height);end
         else begin grid_x<=grid_x+16;tile_x<=grid_x+16;tile_y<=grid_y;tile_h<=grid_h;end
         tile_w<=16;
        end
       end
      end
     endcase
     if((gs==GE_CALC||gs==GE_DRAIN)&&pv)begin
      coordinates[{g_tail,8'd0}+received[7:0]]<={pi,py,px};received<=received+1'b1;
      if(pi)begin any_inside<=1;if(px[18:8]<min_x)min_x<=px[18:8];if(px[18:8]>max_x)max_x<=px[18:8];if(py[18:8]<min_y)min_y<=py[18:8];if(py[18:8]>max_y)max_y<=py[18:8];end
     end
     case(fs)
      PF_IDLE:if(slot_state[f_head]==1)begin
       if(!slot_inside[f_head])begin slot_state[f_head]<=3;slot_cache[f_head]<=0;f_head<=advance(f_head);end
       else if(cache_busy!=2'b11)begin pf_bank<=cache_busy[0]?1'b1:1'b0;fs<=PF_WATER;end
      end
      PF_WATER:if(source_complete_i||source_committed_i>=slot_ry[f_head]+slot_rh[f_head])begin cache_busy[pf_bank]<=1;slot_cache[f_head]<=pf_bank;slot_state[f_head]<=2;fs<=PF_START;end
      PF_START:fs<=PF_WAIT;
      PF_WAIT:if(pf_done)begin slot_state[f_head]<=3;f_head<=advance(f_head);fs<=PF_IDLE;end
     endcase
     case(ps)
      PIX_IDLE:if(slot_state[p_head]==3&&writer_ready)begin row<=0;col<=0;returned<=0;ps<=PIX_ISSUE;end
      PIX_ISSUE:if(col==slot_w[p_head]-1)begin col<=0;if(row==slot_h[p_head]-1)ps<=PIX_DRAIN;else row<=row+1'b1;end else col<=col+1'b1;
     endcase
     if(pixel_valid)begin
      returned<=returned+1'b1;
      if(returned==p_total-1)begin
       slot_state[p_head]<=0;if(slot_inside[p_head])cache_busy[slot_cache[p_head]]<=0;
       p_head<=advance(p_head);ps<=PIX_IDLE;
      end
     end
     if(g_finished&&gs==GE_IDLE&&fs==PF_IDLE&&ps==PIX_IDLE&&slot_state[0]==0&&slot_state[1]==0&&slot_state[2]==0&&writer_idle&&source_complete_i)begin running<=0;done_o<=1;end
    end
   end
  end
 end
endmodule
