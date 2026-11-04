`timescale 1ns/1ps
// Meter the sensor RGB565 stream before crop, tracking, and FPGA Gamma.
// Frame-held flags cross to the SCCB clock using a three-stage toggle.
module camera_exposure_meter #(
 parameter X0=320, X1=960, Y0=180, Y1=540,
 parameter ROI_SAMPLES=1800, FRAME_SAMPLES=7200
)(
 input wire clk, reset_n, vs, de,
 input wire [15:0] rgb,
 output reg valid_o, output reg [1:0] direction_o,
 output reg fast_o, toggle_o
);
 reg vs_d,de_d;
 reg [10:0] x; reg [9:0] y;
 reg [20:0] sum;
 reg [12:0] roi_count, frame_count, clipped;
 wire [7:0] r={rgb[15:11],rgb[15:13]};
 wire [7:0] g={rgb[10:5],rgb[10:9]};
 wire [7:0] b={rgb[4:0],rgb[4:2]};
 wire [9:0] luma={2'b0,r}+{1'b0,g,1'b0}+{2'b0,b}+10'd2;
 wire sample=de && x[3:0]==0 && y[2:0]==0;
 wire in_roi=x>=X0 && x<X1 && y>=Y0 && y<Y1;
 // More than 3% bright/clipped pixels also stops shadow-driven overexposure.
 wire bright=(sum>ROI_SAMPLES*108)||(clipped>FRAME_SAMPLES*3/100);
 wire dark=(sum<ROI_SAMPLES*92)&&(clipped<FRAME_SAMPLES*2/100);
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n)begin
   vs_d<=0;de_d<=0;x<=0;y<=0;sum<=0;roi_count<=0;frame_count<=0;clipped<=0;
   valid_o<=0;direction_o<=0;fast_o<=0;toggle_o<=0;
  end else begin
   vs_d<=vs;de_d<=de;
   if(vs&&!vs_d)begin
    x<=0;y<=0;sum<=0;roi_count<=0;frame_count<=0;clipped<=0;
    valid_o<=(roi_count==ROI_SAMPLES)&&(frame_count==FRAME_SAMPLES);
    direction_o<=bright?2'd2:dark?2'd1:2'd0;
    fast_o<=(sum<ROI_SAMPLES*60)||(sum>ROI_SAMPLES*156)||(clipped>FRAME_SAMPLES/10);
    toggle_o<=~toggle_o;
   end else begin
    if(de)x<=x+1'b1;
    else if(de_d)begin x<=0;y<=y+1'b1;end
    if(sample)begin
     frame_count<=frame_count+1'b1;
     if(luma[9:2]>=8'd248)clipped<=clipped+1'b1;
     if(in_roi)begin sum<=sum+{13'd0,luma[9:2]};roi_count<=roi_count+1'b1;end
    end
   end
  end
 end
endmodule
