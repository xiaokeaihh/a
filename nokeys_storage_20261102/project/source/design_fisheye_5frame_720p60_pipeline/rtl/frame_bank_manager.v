`timescale 1ns/1ps

// Five-frame policy: three raw banks and two corrected banks. A bank is never
// allocated to a writer while it is ready for, or held by, a reader.
// Frame-end/renderer-done must be asserted only after DDR writes complete.
module frame_bank_manager #(parameter integer EARLY_RENDER=0) (
    input  wire       clock,
    input  wire       reset_n,
    input  wire       camera_frame_start_i,
    input  wire       camera_frame_end_i,
    input  wire       camera_frame_complete_i,
    input  wire       render_request_i,
    input wire [10:0] camera_committed_lines_i,
    input  wire       render_done_i,
    input  wire       render_failed_i,
    input  wire       hdmi_frame_start_i,
    output wire       pending_valid_o,output wire [1:0] pending_bank_o,
    output reg        camera_accept_o,
    output reg        camera_drop_o,
    output reg        camera_write_active_o,
    output reg  [1:0] camera_write_bank_o,
    output reg        render_grant_o,
    output reg        render_active_o,
    output reg  [1:0] render_source_bank_o,
    output reg  [1:0] render_destination_bank_o,
    output reg        display_valid_o,
    output reg  [1:0] display_bank_o,
    output reg  [1:0] display_raw_bank_o
);
    reg raw_ready_valid;

    reg [1:0] raw_ready_bank;
    assign pending_valid_o=raw_ready_valid||(EARLY_RENDER&&camera_write_active_o&&camera_committed_lines_i!=0);
    assign pending_bank_o=raw_ready_valid?raw_ready_bank:camera_write_bank_o;
    reg corrected_ready_valid;
    reg [1:0] corrected_ready_bank;
    reg [1:0] corrected_ready_raw_bank;

    reg n_raw_ready_valid;
    reg [1:0] n_raw_ready_bank;
    reg n_corrected_ready_valid;
    reg [1:0] n_corrected_ready_bank;
    reg [1:0] n_corrected_ready_raw_bank;
    reg n_camera_write_active;
    reg [1:0] n_camera_write_bank;
    reg n_render_active;
    reg [1:0] n_render_source_bank;
    reg [1:0] n_render_destination_bank;
    reg n_display_valid;
    reg [1:0] n_display_bank;
    reg [1:0] n_display_raw_bank;
    reg n_camera_accept;
    reg n_camera_drop;
    reg n_render_grant;
    reg [2:0] used_raw;
    reg [1:0] used_corrected;
    reg [1:0] free_raw;
    reg [1:0] free_corrected;

    function [1:0] first_free;
        input [2:0] used;
        begin
            if (!used[0]) first_free = 2'd0;
            else if (!used[1]) first_free = 2'd1;
            else if (!used[2]) first_free = 2'd2;
            else first_free = 2'd3;
        end
    endfunction

    function [1:0] first_free_corrected;
        input [1:0] used;
        begin
            if (!used[0]) first_free_corrected = 2'd0;
            else if (!used[1]) first_free_corrected = 2'd1;
            else first_free_corrected = 2'd2;
        end
    endfunction

    always @* begin
        n_raw_ready_valid = raw_ready_valid;
        n_raw_ready_bank = raw_ready_bank;
        n_corrected_ready_valid = corrected_ready_valid;
        n_corrected_ready_bank = corrected_ready_bank;
        n_corrected_ready_raw_bank = corrected_ready_raw_bank;
        n_camera_write_active = camera_write_active_o;
        n_camera_write_bank = camera_write_bank_o;
        n_render_active = render_active_o;
        n_render_source_bank = render_source_bank_o;
        n_render_destination_bank = render_destination_bank_o;
        n_display_valid = display_valid_o;
        n_display_bank = display_bank_o;
        n_display_raw_bank = display_raw_bank_o;
        n_camera_accept = 1'b0;
        n_camera_drop = 1'b0;
        n_render_grant = 1'b0;
        used_raw = 3'b000;
        used_corrected = 2'b00;
        free_raw = 2'd3;
        free_corrected = 2'd3;

        if (camera_frame_end_i && n_camera_write_active) begin
            n_camera_write_active = 1'b0;
            if (camera_frame_complete_i && !(n_render_active && n_render_source_bank==n_camera_write_bank)) begin
                n_raw_ready_valid = 1'b1;
                n_raw_ready_bank = n_camera_write_bank;
            end
        end

        if ((render_done_i || render_failed_i) && n_render_active) begin
            n_render_active = 1'b0;
            if (render_done_i && !render_failed_i) begin
                n_corrected_ready_valid = 1'b1;
                n_corrected_ready_bank = n_render_destination_bank;
                n_corrected_ready_raw_bank = n_render_source_bank;
            end
        end

        if (hdmi_frame_start_i && n_corrected_ready_valid) begin
            n_display_valid = 1'b1;
            n_display_bank = n_corrected_ready_bank;
            n_display_raw_bank = n_corrected_ready_raw_bank;
            n_corrected_ready_valid = 1'b0;
        end

        used_corrected = 2'b00;
        if (n_display_valid && n_display_bank < 2)
            used_corrected[n_display_bank] = 1'b1;
        if (n_corrected_ready_valid && n_corrected_ready_bank < 2)
            used_corrected[n_corrected_ready_bank] = 1'b1;
        if (n_render_active && n_render_destination_bank < 2)
            used_corrected[n_render_destination_bank] = 1'b1;
        free_corrected = first_free_corrected(used_corrected);

        if (render_request_i && !n_render_active
            && (n_raw_ready_valid||(EARLY_RENDER&&n_camera_write_active&&camera_committed_lines_i!=0))
            && free_corrected != 2'd2) begin
            n_render_grant = 1'b1;
            n_render_active = 1'b1;
            n_render_source_bank = n_raw_ready_valid?n_raw_ready_bank:n_camera_write_bank;
            n_render_destination_bank = free_corrected;
            n_raw_ready_valid = 1'b0;
        end

        used_raw = 3'b000;
        if (n_display_valid)
            used_raw[n_display_raw_bank] = 1'b1;
        if (n_corrected_ready_valid)
            used_raw[n_corrected_ready_raw_bank] = 1'b1;
        if (n_raw_ready_valid)
            used_raw[n_raw_ready_bank] = 1'b1;
        if (n_render_active)
            used_raw[n_render_source_bank] = 1'b1;
        if (n_camera_write_active)
            used_raw[n_camera_write_bank] = 1'b1;
        free_raw = first_free(used_raw);

        if (camera_frame_start_i) begin
            if (!n_camera_write_active && free_raw != 2'd3) begin
                n_camera_accept = 1'b1;
                n_camera_write_active = 1'b1;
                n_camera_write_bank = free_raw;
            end else begin
                n_camera_drop = 1'b1;
            end
        end
    end

    always @(posedge clock) begin
        if (!reset_n) begin
            raw_ready_valid <= 1'b0;
            raw_ready_bank <= 2'd0;
            corrected_ready_valid <= 1'b0;
            corrected_ready_bank <= 2'd0;
            corrected_ready_raw_bank <= 2'd0;
            camera_write_active_o <= 1'b0;
            camera_write_bank_o <= 2'd0;
            render_active_o <= 1'b0;
            render_source_bank_o <= 2'd0;
            render_destination_bank_o <= 2'd0;
            display_valid_o <= 1'b0;
            display_bank_o <= 2'd0;
            display_raw_bank_o <= 2'd0;
            camera_accept_o <= 1'b0;
            camera_drop_o <= 1'b0;
            render_grant_o <= 1'b0;
        end else begin
            raw_ready_valid <= n_raw_ready_valid;
            raw_ready_bank <= n_raw_ready_bank;
            corrected_ready_valid <= n_corrected_ready_valid;
            corrected_ready_bank <= n_corrected_ready_bank;
            corrected_ready_raw_bank <= n_corrected_ready_raw_bank;
            camera_write_active_o <= n_camera_write_active;
            camera_write_bank_o <= n_camera_write_bank;
            render_active_o <= n_render_active;
            render_source_bank_o <= n_render_source_bank;
            render_destination_bank_o <= n_render_destination_bank;
            display_valid_o <= n_display_valid;
            display_bank_o <= n_display_bank;
            display_raw_bank_o <= n_display_raw_bank;
            camera_accept_o <= n_camera_accept;
            camera_drop_o <= n_camera_drop;
            render_grant_o <= n_render_grant;
        end
    end
endmodule
