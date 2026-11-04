`timescale 1ns/1ps
// Two small CDC queues, one existing DDR capture engine. Never mux clocks.
// Tokens preserve SOF/pixel ordering. The reader is faster than either 720p60
// source; gaps carry valid=0 rather than inventing repeated pixels.
module input_token_fifo(
 input wire clock,reset_n,enable_i,
 input wire source_clk,source_vs,source_de,input wire [15:0] source_rgb,
 output wire [16:0] data_o,output wire valid_o,input wire take_i,
 output wire overflow_o
);
 reg [1:0] enabled;reg vs_d,armed,overflow;
 wire reset_fifo=!reset_n||!enable_i;
 wire sof=source_vs&&!vs_d;
 wire full;
 always @(posedge source_clk or posedge reset_fifo)begin
  if(reset_fifo)begin enabled<=0;vs_d<=0;armed<=0;overflow<=0;end
  else begin
   enabled<={enabled[0],1'b1};vs_d<=source_vs;
   if(enabled[1]&&sof)armed<=1;
   if(enabled[1]&&(sof||(armed&&source_de))&&full)overflow<=1;
  end
 end
 video_async_fifo #(.WR_DATA_WIDTH(17),.RD_DATA_WIDTH(17),
  .WR_DEPTH_WIDTH(9),.RD_DEPTH_WIDTH(9),.ALMOST_FULL(480),.ALMOST_EMPTY(1)) fifo(
  .wr_clk(source_clk),.wr_rst(reset_fifo),.wr_data({sof,source_rgb}),
  .wr_en(enabled[1]&&!overflow&&(sof||(armed&&source_de))),.wr_full(full),.almost_full(),.wr_level(),
  .rd_clk(clock),.rd_rst(reset_fifo),.rd_data(data_o),.rd_en(take_i),.rd_empty(),.rd_valid(valid_o),.almost_empty(),.rd_level());
 reg [1:0] overflow_sync;
 always @(posedge clock or negedge reset_n)begin
  if(!reset_n)overflow_sync<=0;else overflow_sync<={overflow_sync[0],overflow};
 end
 assign overflow_o=overflow_sync[1];
endmodule

module dual_video_input #(
 parameter integer QUIET_CYCLES=375000 // 3ms at 125MHz, covers a stopped input
)(
 input wire clock,reset_n,requested_hdmi_i,capture_drained_i,
 input wire camera_clk,camera_vs,camera_de,input wire [15:0] camera_rgb,
 input wire hdmi_clk,hdmi_vs,hdmi_de,input wire [15:0] hdmi_rgb,
 output reg active_hdmi_o,output wire switch_busy_o,output wire capture_abort_o,output reg present_o,output reg error_o,
 output wire vs_o,output reg de_o,output reg [15:0] rgb_o
);
 localparam RUN=0,DRAIN=1,FLUSH=2,WAIT_SOF=3;
 reg [1:0] state,request_sync;
 reg [19:0] quiet;
 reg [5:0] guard;
 reg [4:0] vs_hold;
 wire [16:0] camera_data,hdmi_data;
 wire camera_valid,hdmi_valid,camera_overflow,hdmi_overflow;
 wire enabled=state!=DRAIN&&state!=FLUSH;
 wire [16:0] data=active_hdmi_o?hdmi_data:camera_data;
 wire valid=active_hdmi_o?hdmi_valid:camera_valid;
 wire overflow=active_hdmi_o?hdmi_overflow:camera_overflow;
 wire take=enabled&&vs_hold==0&&valid;
 input_token_fifo camera(.clock(clock),.reset_n(reset_n),.enable_i(enabled&&!active_hdmi_o),
  .source_clk(camera_clk),.source_vs(camera_vs),.source_de(camera_de),.source_rgb(camera_rgb),
  .data_o(camera_data),.valid_o(camera_valid),.take_i(take&&!active_hdmi_o),.overflow_o(camera_overflow));
 input_token_fifo hdmi(.clock(clock),.reset_n(reset_n),.enable_i(enabled&&active_hdmi_o),
  .source_clk(hdmi_clk),.source_vs(hdmi_vs),.source_de(hdmi_de),.source_rgb(hdmi_rgb),
  .data_o(hdmi_data),.valid_o(hdmi_valid),.take_i(take&&active_hdmi_o),.overflow_o(hdmi_overflow));
 assign vs_o=vs_hold!=0;
 assign switch_busy_o=state!=RUN||request_sync[1]!=active_hdmi_o;
 // Retire the owned DDR write, without waiting for a damaged frame's
 // missing pixels. Keep the request asserted through the FIFO flush.
 assign capture_abort_o=state==DRAIN||state==FLUSH;
 always @(posedge clock or negedge reset_n)begin
  if(!reset_n)begin state<=FLUSH;active_hdmi_o<=0;present_o<=0;error_o<=0;
   request_sync<=0;quiet<=0;guard<=0;vs_hold<=0;de_o<=0;rgb_o<=0;end
  else begin
   request_sync<={request_sync[0],requested_hdmi_i};de_o<=0;
   if(vs_hold!=0)vs_hold<=vs_hold-1'b1;
   if(take)quiet<=0;else if(quiet<QUIET_CYCLES)quiet<=quiet+1'b1;
   case(state)
    RUN:begin
     if(overflow)begin error_o<=1;state<=DRAIN;present_o<=0;guard<=0;end
     else if(request_sync[1]!=active_hdmi_o&&((take&&data[16])||quiet==QUIET_CYCLES))begin
      state<=DRAIN;present_o<=0;guard<=0;
     end else if(take)begin
      if(data[16])begin vs_hold<=16;present_o<=1;end
      else begin de_o<=1;rgb_o<=data[15:0];end
     end
     if(quiet==QUIET_CYCLES)present_o<=0;
    end
    DRAIN:begin
     // The writer stops issuing new lines and retires its owned AXI burst.
     // Residual/failed frame data is discarded only after that retirement.
     if(guard<63)guard<=guard+1'b1;
     if(guard==63&&capture_drained_i)begin
      active_hdmi_o<=request_sync[1];state<=FLUSH;guard<=0;
     end
    end
    FLUSH:begin
     if(guard==31)begin state<=WAIT_SOF;guard<=0;quiet<=0;end
     else guard<=guard+1'b1;
    end
    WAIT_SOF:begin
     if(request_sync[1]!=active_hdmi_o)begin state<=DRAIN;guard<=0;end
     else if(overflow)begin error_o<=1;state<=DRAIN;guard<=0;end
     else if(take&&data[16])begin vs_hold<=16;state<=RUN;present_o<=1;error_o<=0;end
    end
   endcase
  end
 end
endmodule
