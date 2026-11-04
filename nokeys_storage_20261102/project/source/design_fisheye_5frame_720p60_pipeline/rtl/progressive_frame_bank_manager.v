`timescale 1ns/1ps

// Three RAW and two COR banks. The live scan may own the rendering bank,
// but reads only its committed prefix. Keep a good fallback and a retired
// command's frame pair; never free a bank merely because VSYNC changed.
module progressive_frame_bank_manager (
    input wire clock,reset_n,camera_frame_start_i,camera_frame_end_i,camera_frame_complete_i,
    input wire render_request_i,render_done_i,render_failed_i,hdmi_frame_start_i,
    input wire [10:0] camera_committed_lines_i,
    input wire live_admit_i,scan_failed_i,display_command_busy_i,
    input wire prefer_live_i,
    input wire prefer_fresh_i,
    output wire pending_valid_o,
    output wire [1:0] pending_bank_o,
    output reg camera_accept_o,camera_drop_o,camera_write_active_o,
    output reg [1:0] camera_write_bank_o,
    output reg render_grant_o,render_active_o,
    output reg [1:0] render_source_bank_o,render_destination_bank_o,
    output reg display_valid_o,display_live_o,display_fault_o,
    output reg [1:0] display_bank_o,display_raw_bank_o
);
    reg raw_ready,cor_ready,good_valid,retired_valid;
    reg [1:0] raw_ready_bank,cor_ready_bank,cor_ready_raw,good_bank,good_raw,retired_bank,retired_raw;
    reg [2:0] consumed_raw;
    reg n_raw_ready,n_cor_ready,n_good_valid,n_retired_valid;
    reg [1:0] n_raw_ready_bank,n_cor_ready_bank,n_cor_ready_raw,n_good_bank,n_good_raw,n_retired_bank,n_retired_raw;
    reg [2:0] n_consumed_raw;
    reg n_camera_active,n_render_active,n_display_valid,n_display_live,n_display_fault;
    reg [1:0] n_camera_bank,n_render_source,n_render_destination,n_display_bank,n_display_raw;
    reg n_camera_accept,n_camera_drop,n_render_grant;
    reg [2:0] used_raw;
    reg [1:0] used_cor,free_raw,free_cor;
    wire fresh_source=prefer_fresh_i===1'b1;
    // Keep the first dependency-band geometry ahead of source row233 while
    // allowing the preceding streamed frame's tail to retire. At native rate
    // 160 source rows leave more than0.5ms of geometry headroom to that band.
    wire capture_launch_window=camera_committed_lines_i!=0&&(!fresh_source||camera_committed_lines_i<=160);
    assign pending_valid_o=(!fresh_source&&raw_ready)||(camera_write_active_o&&capture_launch_window&&!consumed_raw[camera_write_bank_o]);
    assign pending_bank_o=!fresh_source&&raw_ready ? raw_ready_bank : camera_write_bank_o;
    function [1:0] first_raw;
        input [2:0] used;
        begin first_raw=!used[0] ? 0 : !used[1] ? 1 : !used[2] ? 2 : 3;end
    endfunction
    always @*begin
        n_raw_ready=raw_ready;n_raw_ready_bank=raw_ready_bank;n_cor_ready=cor_ready;n_cor_ready_bank=cor_ready_bank;n_cor_ready_raw=cor_ready_raw;
        n_good_valid=good_valid;n_good_bank=good_bank;n_good_raw=good_raw;
        n_retired_valid=retired_valid;n_retired_bank=retired_bank;n_retired_raw=retired_raw;n_consumed_raw=consumed_raw;
        n_camera_active=camera_write_active_o;n_camera_bank=camera_write_bank_o;
        n_render_active=render_active_o;n_render_source=render_source_bank_o;n_render_destination=render_destination_bank_o;
        n_display_valid=display_valid_o;n_display_bank=display_bank_o;n_display_raw=display_raw_bank_o;
        n_display_live=display_live_o;n_display_fault=display_fault_o;
        n_camera_accept=0;n_camera_drop=0;n_render_grant=0;
        if(!display_command_busy_i)n_retired_valid=0;
        if(camera_frame_end_i&&n_camera_active)begin
            n_camera_active=0;
            if(camera_frame_complete_i&&!n_consumed_raw[n_camera_bank])begin n_raw_ready=1;n_raw_ready_bank=n_camera_bank;end
        end
        if((render_done_i||render_failed_i)&&n_render_active)begin
            n_render_active=0;
            if(render_done_i&&!render_failed_i)begin
                // A live frame is already published. Queueing its completion
                // again would repeat it at the next VSYNC and block the next
                // live producer. Keep it as the good fallback without a second
                // publication; unshown completed frames still enter the queue.
                if(n_display_valid&&n_display_bank==n_render_destination&&n_display_raw==n_render_source)n_cor_ready=0;
                else begin n_cor_ready=1;n_cor_ready_bank=n_render_destination;n_cor_ready_raw=n_render_source;end
                n_good_valid=1;n_good_bank=n_render_destination;n_good_raw=n_render_source;
            end else if(n_display_live&&n_display_bank==n_render_destination)n_display_fault=1;
        end
        if(scan_failed_i&&n_display_valid)n_display_fault=1;
        // A late completed RAW frame cannot meet the certified output epoch.
        // Keep all COR/display/retired ownership intact; wait for the next
        // capture's leading rows instead of repeatedly starting a stale frame
        // just after output VS released its COR slot. In-flight work drains.
        if(fresh_source)n_raw_ready=0;
        if(hdmi_frame_start_i)begin
            n_display_fault=0;
            if(n_render_active&&live_admit_i&&(prefer_live_i===1'b1))begin
                // Native HDMI may already have a newer certified prefix.
                // Discard the superseded queue entry, but retain good_bank
                // as the complete fallback until the new producer succeeds.
                n_display_valid=1;n_display_bank=n_render_destination;n_display_raw=n_render_source;n_display_live=1;n_cor_ready=0;
            end else if(n_cor_ready)begin
                n_display_valid=1;n_display_bank=n_cor_ready_bank;n_display_raw=n_cor_ready_raw;n_display_live=0;n_cor_ready=0;
            end else if(n_render_active&&live_admit_i)begin
                n_display_valid=1;n_display_bank=n_render_destination;n_display_raw=n_render_source;n_display_live=1;
            end else if(n_good_valid)begin
                n_display_valid=1;n_display_bank=n_good_bank;n_display_raw=n_good_raw;n_display_live=0;
            end else begin n_display_valid=0;n_display_live=0;end
            if(display_valid_o&&display_command_busy_i&&
               (!n_display_valid||n_display_bank!=display_bank_o||n_display_raw!=display_raw_bank_o))begin
                n_retired_valid=1;n_retired_bank=display_bank_o;n_retired_raw=display_raw_bank_o;
            end
        end
        used_cor=0;
        if(n_display_valid)used_cor[n_display_bank]=1;
        if(n_good_valid)used_cor[n_good_bank]=1;
        if(n_retired_valid)used_cor[n_retired_bank]=1;
        if(n_cor_ready)used_cor[n_cor_ready_bank]=1;
        if(n_render_active)used_cor[n_render_destination]=1;
        free_cor=!used_cor[0] ? 0 : !used_cor[1] ? 1 : 2;
        if(render_request_i&&!n_render_active&&free_cor<2&&
           (n_raw_ready||(n_camera_active&&capture_launch_window&&!n_consumed_raw[n_camera_bank])))begin
            n_render_active=1;n_render_grant=1;n_render_destination=free_cor;
            n_render_source=n_raw_ready ? n_raw_ready_bank : n_camera_bank;
            n_raw_ready=0;n_consumed_raw[n_render_source]=1;
        end
        used_raw=0;
        if(n_display_valid)used_raw[n_display_raw]=1;
        if(n_good_valid)used_raw[n_good_raw]=1;
        if(n_retired_valid)used_raw[n_retired_raw]=1;
        if(n_cor_ready)used_raw[n_cor_ready_raw]=1;
        if(n_raw_ready)used_raw[n_raw_ready_bank]=1;
        if(n_render_active)used_raw[n_render_source]=1;
        if(n_camera_active)used_raw[n_camera_bank]=1;
        free_raw=first_raw(used_raw);
        if(camera_frame_start_i)begin
            if(!n_camera_active&&free_raw<3)begin
                n_camera_accept=1;n_camera_active=1;n_camera_bank=free_raw;n_consumed_raw[free_raw]=0;
            end else n_camera_drop=1;
        end
    end
    always @(posedge clock)begin
        if(!reset_n)begin
            raw_ready<=0;cor_ready<=0;good_valid<=0;retired_valid<=0;consumed_raw<=0;
            raw_ready_bank<=0;cor_ready_bank<=0;cor_ready_raw<=0;good_bank<=0;good_raw<=0;retired_bank<=0;retired_raw<=0;
            camera_accept_o<=0;camera_drop_o<=0;camera_write_active_o<=0;camera_write_bank_o<=0;
            render_grant_o<=0;render_active_o<=0;render_source_bank_o<=0;render_destination_bank_o<=0;
            display_valid_o<=0;display_live_o<=0;display_fault_o<=0;display_bank_o<=0;display_raw_bank_o<=0;
        end else begin
            raw_ready<=n_raw_ready;raw_ready_bank<=n_raw_ready_bank;cor_ready<=n_cor_ready;cor_ready_bank<=n_cor_ready_bank;cor_ready_raw<=n_cor_ready_raw;
            good_valid<=n_good_valid;good_bank<=n_good_bank;good_raw<=n_good_raw;retired_valid<=n_retired_valid;retired_bank<=n_retired_bank;retired_raw<=n_retired_raw;
            consumed_raw<=n_consumed_raw;camera_accept_o<=n_camera_accept;camera_drop_o<=n_camera_drop;
            camera_write_active_o<=n_camera_active;camera_write_bank_o<=n_camera_bank;render_grant_o<=n_render_grant;render_active_o<=n_render_active;
            render_source_bank_o<=n_render_source;render_destination_bank_o<=n_render_destination;
            display_valid_o<=n_display_valid;display_bank_o<=n_display_bank;display_raw_bank_o<=n_display_raw;
            display_live_o<=n_display_live;display_fault_o<=n_display_fault;
        end
    end
endmodule
