`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Myminieye
// Engineer: Ori
// 
// Create Date:    2021-08-06 15:16 
// Design Name:  
// Module Name:    sync_vg
// QQ Group   :    
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
//    VS     ______                                       ______
//HS  __    |      |_______________……____________________|      |
//   |       h_sync  h_bp       h_act                h_fp
//   |__                    _______________________
//DE    |   _______________|                       |_____________
//      |
//      .
//      |
//    __|
//   |  
//   |__ 
//      |
// Revision: v1.0
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`define UD #1

module sync_vg # (
    parameter               X_BITS=12,
    parameter               Y_BITS=12,
 
  // CTA 1280x720p60: 1650 x 750 total at the existing 74.25 MHz pixel clock.
    parameter V_TOTAL = 12'd750,
    parameter V_FP = 12'd5,
    parameter V_BP = 12'd20,
    parameter V_SYNC = 12'd5,
    parameter V_ACT = 12'd720,
    parameter H_TOTAL = 12'd1650,
    parameter H_FP = 12'd110,
    parameter H_BP = 12'd220,
    parameter H_SYNC = 12'd40,
    parameter H_ACT = 12'd1280,
    parameter HV_OFFSET = 12'd0 

)(
    input                   clk,
    input                   rstn,
    input [1:0]             phase_adjust_i,
    output reg              vs_out,
    output reg              hs_out,
    output reg              de_out,
    output reg              de_re,
    output reg [X_BITS-1:0] x_act,
    output wire frame_end_o,
    output reg [Y_BITS-1:0] y_act
);

    reg [X_BITS-1:0] h_count;
    reg [Y_BITS-1:0] v_count;
    reg [Y_BITS-1:0] frame_last_line;
    
    assign frame_end_o = rstn && h_count==H_TOTAL-1 && v_count==frame_last_line;
    // Optional input defaults to ordinary timing when left unconnected.
    // Sample after all active rows; only the front porch can change.
    always @(posedge clk) begin
        if(!rstn)frame_last_line<=V_TOTAL-1;
        else if(v_count==V_SYNC+V_BP+V_ACT && h_count==0)begin
            if(phase_adjust_i===2'b01)frame_last_line<=V_TOTAL;
            else if(phase_adjust_i===2'b10 && V_FP>1)frame_last_line<=V_TOTAL-2;
            else frame_last_line<=V_TOTAL-1;
        end
    end
    /* horizontal counter */
    always @(posedge clk)
    begin
        if (!rstn)
            h_count <= `UD 0;
        else
        begin
            if (h_count < H_TOTAL - 1)
                h_count <= `UD h_count + 1;
            else
                h_count <= `UD 0;
        end
    end
    
    /* vertical counter */
    always @(posedge clk)
    begin
        if (!rstn)
            v_count <= `UD 0;
        else
        if (h_count == H_TOTAL - 1)
        begin
            if (v_count == frame_last_line)
                v_count <= `UD 0;
            else
                v_count <= `UD v_count + 1;
        end
    end
    
    always @(posedge clk)
    begin
        if (!rstn)
            hs_out <= `UD 4'b0;
        else 
            hs_out <= `UD ((h_count < H_SYNC));
    end
    
    always @(posedge clk)
    begin
        if (!rstn)
            vs_out <= `UD 4'b0;
        else 
        begin
            if ((v_count == 0) && (h_count == HV_OFFSET))
                vs_out <= `UD 1'b1;
            else if ((v_count == V_SYNC) && (h_count == HV_OFFSET))
                vs_out <= `UD 1'b0;
            else
                vs_out <= `UD vs_out;
        end
    end
    
    always @(posedge clk)
    begin
        if (!rstn)
            de_out <= `UD 4'b0;
        else
            de_out <= (((v_count >= V_SYNC + V_BP) && (v_count <= V_TOTAL - V_FP - 1)) && 
                      ((h_count >= H_SYNC + H_BP) && (h_count <= H_TOTAL - H_FP - 1)));
    end

    always @(posedge clk)
    begin
        if (!rstn)
            de_re <= `UD 4'b0;
        else
            de_re <= (((v_count >= V_SYNC + V_BP) && (v_count <= V_TOTAL - V_FP - 1)) && 
                      ((h_count >= H_SYNC + H_BP-2'd2) && (h_count <= H_TOTAL - H_FP - 3)));
    end    
    // active pixels counter output
    always @(posedge clk)
    begin
        if (!rstn)
            x_act <= `UD 'd0;
        else 
        begin
        /* X coords – for a backend pattern generator */
            if(h_count > (H_SYNC + H_BP - 1'b1))
                x_act <= `UD (h_count - (H_SYNC + H_BP));
            else
                x_act <= `UD 'd0;
        end
    end
    
    always @(posedge clk)
    begin
        if (!rstn)
            y_act <= `UD 'd0;
        else 
        begin
            /* Y coords – for a backend pattern generator */
            if(v_count > (V_SYNC + V_BP - 1'b1))
                y_act <= `UD (v_count - (V_SYNC + V_BP));
            else
                y_act <= `UD 'd0;
        end
    end
    
endmodule
