`timescale 1ns/1ps

// Remote view control only. Physical keys and their debounce/event CDC are removed.
// Keep sequence decoding and frame-boundary layout application unchanged.
module key0_mode_control #(
    parameter integer DEBOUNCE_CYCLES = 540000 // 20 ms at 27 MHz
) (
    input wire sys_clk,
    input wire sys_reset_n,
    input wire key0,
    input wire ddr_clk,
    input wire ddr_reset_n,
    input wire [7:0] view_seq_i,
    input wire [2:0] requested_view_i,
    output reg [1:0] requested_mode_o,
    output reg [2:0] comparison_view_o
);
    reg [7:0] view_seq_seen;
    always @(posedge ddr_clk or negedge ddr_reset_n) begin
        if (!ddr_reset_n) begin
            requested_mode_o <= 2'd0;
            comparison_view_o <= 3'd6;
            view_seq_seen <= 8'd0;
        end else begin
            // A new web choice selects a visible layout as well as a view.
            // Retried packets with the same sequence do not undo a KEY0 press.
            if (view_seq_i != view_seq_seen) begin
                view_seq_seen <= view_seq_i;
                requested_mode_o <= requested_view_i == 3'd0 ? 2'd0 :
                                    requested_view_i == 3'd7 ? 2'd3 :
                                    requested_view_i == 3'd5 ? 2'd1 : 2'd2;
                if(requested_view_i>=1 && requested_view_i<=4 || requested_view_i==6)
                    comparison_view_o<=requested_view_i;
                else if(requested_view_i==0)
                    comparison_view_o<=3'd6;
            end
        end
    end
endmodule
