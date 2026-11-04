`timescale 1ns/1ps
// Registered output keeps the previous one-clock RGB/sync alignment.
// Diagnostic patches are true RGB888 and bypass all camera/ISP/tone processing.
module hdmi_color_output(
 input wire clk, reset_n, vs_i, hs_i, de_i,
 input wire [15:0] rgb_i,
 input wire diagnostic_async_i,
 output reg diagnostic_active_o,
 output reg [7:0] r_o,g_o,b_o,
 output reg vs_o,hs_o,de_o
);
 reg test_meta,test_sync,vs_d,de_d;
 reg [10:0] x;reg [9:0] y;
 reg [7:0] tr,tg,tb,gray;
 reg [2:0] band;
 always @* begin
  if(x<160)band=0;else if(x<320)band=1;else if(x<480)band=2;else if(x<640)band=3;
  else if(x<800)band=4;else if(x<960)band=5;else if(x<1120)band=6;else band=7;
  case(band)
   0:begin tr=255;tg=255;tb=255;gray=0;end
   1:begin tr=255;tg=255;tb=0;gray=32;end
   2:begin tr=0;tg=255;tb=255;gray=64;end
   3:begin tr=0;tg=255;tb=0;gray=96;end
   4:begin tr=255;tg=0;tb=255;gray=128;end
   5:begin tr=255;tg=0;tb=0;gray=160;end
   6:begin tr=0;tg=0;tb=255;gray=192;end
   7:begin tr=0;tg=0;tb=0;gray=255;end
  endcase
  if(y>=360)begin tr=gray;tg=gray;tb=gray;end
 end
 always @(posedge clk or negedge reset_n)begin
  if(!reset_n)begin
   test_meta<=0;test_sync<=0;diagnostic_active_o<=0;vs_d<=0;de_d<=0;x<=0;y<=0;
   r_o<=0;g_o<=0;b_o<=0;vs_o<=0;hs_o<=0;de_o<=0;
  end else begin
   test_meta<=diagnostic_async_i;test_sync<=test_meta;vs_d<=vs_i;de_d<=de_i;
   if(vs_i&&!vs_d)begin x<=0;y<=0;diagnostic_active_o<=test_sync;end
   else if(de_i)x<=x+1'b1;
   else if(de_d)begin x<=0;y<=y+1'b1;end
   if(diagnostic_active_o)begin r_o<=tr;g_o<=tg;b_o<=tb;end
   else begin
    r_o<={rgb_i[15:11],rgb_i[15:13]};
    g_o<={rgb_i[10:5],rgb_i[10:9]};
    b_o<={rgb_i[4:0],rgb_i[4:2]};
   end
   vs_o<=vs_i;hs_o<=hs_i;de_o<=de_i;
  end
 end
endmodule
