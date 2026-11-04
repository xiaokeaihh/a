`timescale 1ns/1ps
// 115200 8N1. Packet A5 5A SEQ VIEW CRC8(SEQ,VIEW), polynomial 07.
// Bundled-data toggle mailboxes: payload held until receiving clock acknowledges.
module multiview_control #(parameter CLK_HZ=27000000, BAUD=115200)(
 input wire sys_clk,sys_reset_n,uart_rx,
 input wire ddr_clk,ddr_reset_n,
 output reg [2:0] requested_view_o,output reg [7:0] requested_seq_o,
 input wire pixel_clk,pixel_reset_n,vsync,content_de,
 input wire [2:0] display_view_i,input wire [7:0] display_seq_i,
 input wire [1:0] display_mode_i,input wire display_stabilized_i,
 output reg shown_stabilized_o,
 output reg [2:0] shown_view_o,output reg [7:0] shown_seq_o,
 output reg [1:0] shown_mode_o,output reg shown_valid_o,
 output reg static_test_o,
 output reg fast_uart_o,output reg stabilization_enable_o,
 output reg pose_valid_o,output reg [31:0] pose_frame_o,pose_tick_o,
 output reg [287:0] pose_matrix_o,
 output wire [1439:0] pose_views_o,output wire pose_allviews_o,
 output reg [2:0] pose_view_o,output reg [7:0] pose_sequence_o,output reg pose_tagged_o,
 output reg control_valid_o,output reg [7:0] control_code_o,control_seq_o,
 output reg [47:0] attitude_data_o,output reg attitude_toggle_o
);
 wire [7:0] rb;wire rv;
 multiview_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) rx(.clk(sys_clk),.rst_n(sys_reset_n),.rx(uart_rx),.fast_i(fast_uart_o),.data(rb),.valid(rv));
 function [7:0] crc_byte;input [7:0] crc,data;reg [7:0] a;integer k;
 begin a=crc^data;for(k=0;k<8;k=k+1)a=a[7]?(a<<1)^8'h07:a<<1;crc_byte=a;end endfunction
 reg [3:0] parser;reg [7:0] seq,view,crc;
 reg [15:0] timeout_count;
 reg [12:0] cmd_payload;
 reg [359:0] pose_shift,pose_payload;reg [7:0] pose_index;
 reg [7:0] pose_sequence_payload;reg pose_tagged_payload;
 assign pose_views_o=1440'd0;assign pose_allviews_o=1'b0;
 integer pose_byte;
 reg pose_toggle,pose_ack;reg [2:0] pose_ack_sync,pose_sync;reg cmd_toggle,cmd_ack;
 reg [2:0] ack_sync,cmd_sync;
 always @(posedge sys_clk or negedge sys_reset_n) begin
  if(!sys_reset_n) begin parser<=0;seq<=0;view<=0;crc<=0;cmd_payload<=0;cmd_toggle<=0;ack_sync<=0;timeout_count<=0;fast_uart_o<=0;pose_toggle<=0;pose_shift<=0;pose_payload<=0;pose_index<=0;pose_ack_sync<=0;pose_sequence_payload<=0;pose_tagged_payload<=0;control_valid_o<=0;control_code_o<=0;control_seq_o<=0;attitude_data_o<=0;attitude_toggle_o<=0;end
  else begin
   control_valid_o<=0;
   ack_sync<={ack_sync[1:0],cmd_ack};pose_ack_sync<={pose_ack_sync[1:0],pose_ack};
   if(parser!=0) begin
    timeout_count<=timeout_count+1'b1;
    if(timeout_count==16'hffff)begin parser<=0;timeout_count<=0;pose_index<=0;end
   end
   if(rv) begin
    timeout_count<=0;
    case(parser)
     0:if(rb==8'ha5)parser<=1;
     1:if(rb==8'h5a)parser<=2;else parser<=rb==8'ha5 ? 1:0;
     2:begin seq<=rb;crc<=crc_byte(0,rb);parser<=3;end
     3:begin view<=rb;crc<=crc_byte(crc,rb);pose_index<=0;parser<=rb==8'h90||rb==8'h92 ? 5 : rb==8'h91 ? 7 : rb==8'h93 ? 8 : 4;end
     4:begin
      parser<=0;
      if(rb==crc)begin
       if(view==8'h82||view==8'h83)fast_uart_o<=view[0];
       if((view>=8'h86&&view<=8'h8f)||(view>=8'h94&&view<=8'h99))begin control_valid_o<=1;control_code_o<=view;control_seq_o<=seq;end
       if((view<8||view==8'h84||view==8'h85)&&ack_sync[2]==cmd_toggle)begin cmd_payload<={view==8'h84||view==8'h85,view[0],seq,view[2:0]};cmd_toggle<=~cmd_toggle;end
      end
     end
     5:begin
      // Fixed byte lanes expose clock-enables without a wide variable write mux.
      for(pose_byte=0;pose_byte<45;pose_byte=pose_byte+1)
       if(pose_index==pose_byte)pose_shift[pose_byte*8+:8]<=rb;
      crc<=crc_byte(crc,rb);
      if(pose_index==8'd44)parser<=6;
      else pose_index<=pose_index+1'b1;
     end
     6:begin
      parser<=0;
      if(rb==crc&&pose_ack_sync[2]==pose_toggle&&
         ((view==8'h90&&pose_shift[7:0]==1)||
          (view==8'h92&&(pose_shift[7:0]==8'h36||pose_shift[7:0]==8'h37))))begin
       pose_payload<=pose_shift;pose_sequence_payload<=seq;pose_tagged_payload<=view==8'h92;pose_toggle<=~pose_toggle;
      end
     end
     // Drain an obsolete 225-byte six-view payload plus CRC atomically. Its
     // contents cannot be mistaken for view commands or a new packet header.
     7:if(pose_index==8'd225)begin parser<=0;pose_index<=0;end else pose_index<=pose_index+1'b1;
     8:begin
      for(pose_byte=0;pose_byte<7;pose_byte=pose_byte+1)if(pose_index==pose_byte)pose_shift[pose_byte*8+:8]<=rb;
      crc<=crc_byte(crc,rb);if(pose_index==6)parser<=9;else pose_index<=pose_index+1'b1;
     end
     9:begin parser<=0;if(rb==crc&&pose_shift[7:0]==1)begin attitude_data_o<=pose_shift[55:8];attitude_toggle_o<=~attitude_toggle_o;end end
     default:parser<=0;
    endcase
   end
  end
 end
 always @(posedge ddr_clk or negedge ddr_reset_n) begin
  if(!ddr_reset_n)begin cmd_sync<=0;cmd_ack<=0;requested_view_o<=6;requested_seq_o<=0;static_test_o<=0;stabilization_enable_o<=0;pose_valid_o<=0;pose_sync<=0;pose_ack<=0;pose_frame_o<=0;pose_tick_o<=0;pose_matrix_o<=0;pose_view_o<=7;pose_sequence_o<=0;pose_tagged_o<=0;end
  else begin
   cmd_sync<={cmd_sync[1:0],cmd_toggle};pose_sync<={pose_sync[1:0],pose_toggle};pose_valid_o<=0;
   if(pose_sync[2]!=pose_ack)begin pose_frame_o<=pose_payload[39:8];pose_tick_o<=pose_payload[71:40];pose_matrix_o<=pose_payload[359:72];pose_view_o<=pose_tagged_payload?pose_payload[2:0]:3'd7;pose_sequence_o<=pose_sequence_payload;pose_tagged_o<=pose_tagged_payload;pose_valid_o<=1;pose_ack<=pose_sync[2];end
   if(cmd_sync[2]!=cmd_ack)begin if(cmd_payload[12])stabilization_enable_o<=cmd_payload[11];else {requested_seq_o,requested_view_o}<=cmd_payload[10:0];cmd_ack<=cmd_sync[2];end
  end
 end
 // Capture the view actually consumed by HDMI, after blanking and at the first
 // valid content pixel. An accepted command is never reported as displayed.
 reg [13:0] display_meta,display_sync;
 reg armed,vs_prev;reg [13:0] fb_payload;reg fb_toggle,fb_ack;
 reg [2:0] fb_ack_sync,fb_sync;
 always @(posedge pixel_clk or negedge pixel_reset_n) begin
  if(!pixel_reset_n)begin display_meta<=0;display_sync<=0;armed<=0;vs_prev<=0;fb_payload<=0;fb_toggle<=0;fb_ack_sync<=0;end
  else begin
   display_meta<={(display_stabilized_i===1'b1),display_mode_i,display_seq_i,display_view_i};display_sync<=display_meta;
   fb_ack_sync<={fb_ack_sync[1:0],fb_ack};vs_prev<=vsync;
   if(vsync&&!vs_prev)armed<=1;
   else if(armed&&content_de&&fb_toggle==fb_ack_sync[2])begin
    fb_payload<=display_sync;fb_toggle<=~fb_toggle;armed<=0;
   end
  end
 end
 always @(posedge sys_clk or negedge sys_reset_n) begin
  if(!sys_reset_n)begin fb_sync<=0;fb_ack<=0;shown_view_o<=6;shown_seq_o<=0;shown_mode_o<=0;shown_valid_o<=0;shown_stabilized_o<=0;end
  else begin
   fb_sync<={fb_sync[1:0],fb_toggle};
   if(fb_sync[2]!=fb_ack)begin {shown_stabilized_o,shown_mode_o,shown_seq_o,shown_view_o}<=fb_payload;shown_valid_o<=1;fb_ack<=fb_sync[2];end
  end
 end
endmodule

module multiview_uart_rx #(parameter CLK_HZ=27000000,BAUD=115200)(
 input wire clk,rst_n,rx,input wire fast_i,output reg [7:0] data,output reg valid
);
 localparam DIV=(CLK_HZ+BAUD/2)/BAUD;
 localparam FAST_DIV=(CLK_HZ+921600/2)/921600;
 wire [15:0] divisor=(fast_i===1'b1)?FAST_DIV:DIV;
 reg [1:0] sync;reg [1:0] state;reg [15:0] count;reg [2:0] bitpos;reg [7:0] shift;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin sync<=3;state<=0;count<=0;bitpos<=0;shift<=0;data<=0;valid<=0;end
  else begin
   sync<={sync[0],rx};valid<=0;
   case(state)
    0:if(!sync[1])begin count<=divisor/2-1;state<=1;end
    1:if(count==0)begin
     if(!sync[1])begin count<=divisor-1;bitpos<=0;state<=2;end else state<=0;
    end else count<=count-1'b1;
    2:if(count==0)begin shift[bitpos]<=sync[1];count<=divisor-1;
     if(bitpos==7)state<=3;else bitpos<=bitpos+1'b1;
    end else count<=count-1'b1;
    3:if(count==0)begin if(sync[1])begin data<=shift;valid<=1;end state<=0;end else count<=count-1'b1;
   endcase
  end
 end
endmodule
