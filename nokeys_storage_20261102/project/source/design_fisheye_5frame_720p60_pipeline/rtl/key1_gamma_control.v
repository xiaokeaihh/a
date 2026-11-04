`timescale 1ns/1ps

// Remote Gamma control only. Preserve held-level CDC and blanking-only updates.
module key1_gamma_control #(
    parameter integer DEBOUNCE_CYCLES = 540000
) (
    input wire sys_clk, input wire sys_reset_n, input wire key1,
    input wire pixel_clk, input wire pixel_reset_n, input wire vsync,
    input wire remote_valid_i,remote_enable_i,
    input wire toggle_request_i,
    output wire requested_enable_o,
    output reg enable_o
);
    reg requested_enable;
    assign requested_enable_o=requested_enable;
    always @(posedge sys_clk or negedge sys_reset_n) begin
        if (!sys_reset_n) begin
            requested_enable <= 1'b1;
        end else begin
            if(toggle_request_i===1'b1)requested_enable<=~requested_enable;
            if(remote_valid_i===1'b1)requested_enable<=remote_enable_i;
        end
    end

    reg enable_meta, enable_sync;
    always @(posedge pixel_clk or negedge pixel_reset_n) begin
        if (!pixel_reset_n) begin
            enable_meta <= 1'b1; enable_sync <= 1'b1; enable_o <= 1'b1;
        end else begin
            enable_meta <= requested_enable;
            enable_sync <= enable_meta;
            // VSYNC remains inside blanking, including the synchronizer settling.
            if (vsync) enable_o <= enable_sync;
        end
    end
endmodule
