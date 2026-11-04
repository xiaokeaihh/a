`timescale 1ns/1ps

// Tags an accepted camera frame, carries its first-pixel timestamp through
// the raw and corrected bank ownership changes, and measures its first HDMI
// active pixel. The reported FPS counts new corrected frames, not HDMI scans.
module video_frame_metrics #(
    // 125 MHz DDR clock: exactly ten seconds. Override for simulation only.
    parameter integer CAMERA_MEASURE_CYCLES = 1250000000
) (
    input  wire        ddr_clk,
    input  wire        reset_n,
    input  wire        vin_clk,
    input  wire        camera_vsync,
    input  wire        camera_pixel_valid,
    input  wire        camera_accept,
    input  wire        camera_frame_start,
    input  wire        camera_frame_complete,
    input  wire [1:0]  camera_bank,
    input  wire        render_grant,
    input  wire [1:0]  render_source_bank,
    input  wire [1:0]  render_destination_bank,
    input  wire        render_done,
    input  wire        render_failed,
    input  wire        display_valid,
    input  wire [1:0]  display_bank,
    input  wire        display_live_i,
    output reg         first_before_done_o,
    input  wire        vout_clk,
    input  wire        hdmi_vsync,
    input  wire        hdmi_pixel_valid,
    input  wire        hdmi_de,
    input wire [1:0] processing_state_i,
    input  wire [1:0]  display_mode_i,
    input  wire [2:0]  display_view_i,
    output wire [55:0] pane_first_tenths_o,pane_end_tenths_o,
    output wire [3:0] pane_first_valid_o,pane_end_valid_o,
    output wire [6:0] pane_layout_o,
    output wire [13:0] latency_tenth_ms,
    output wire        latency_valid,
    output wire [13:0] capture_tenth_ms,
    output wire [13:0] queue_tenth_ms,
    output wire [13:0] render_tenth_ms,
    output wire [13:0] display_tenth_ms,
    output wire [7:0]  corrected_fps,
    output wire [11:0] camera_fps_tenths,
    output wire        camera_rate_valid,
    output wire [7:0]  raw_fps,
    output wire [7:0]  render_fps,
    output wire [11:0] output_refresh_tenths,
    output wire        output_refresh_valid,
    output wire [383:0] diagnostics_ddr_o,output reg new_display_pulse_o
);
    // A one-bit event crosses each clock boundary. Bank IDs and timestamps
    // are read only in the DDR clock domain, where bank ownership is held.
    reg cam_seen;
    reg cam_toggle;
    always @(posedge vin_clk or negedge reset_n) begin
        if (!reset_n) begin
            cam_seen <= 1'b0;
            cam_toggle <= 1'b0;
        end else if (camera_vsync) begin
            cam_seen <= 1'b0;
        end else if (camera_pixel_valid && !cam_seen) begin
            cam_seen <= 1'b1;
            cam_toggle <= ~cam_toggle;
        end
    end

    reg hdmi_seen;
    reg hdmi_toggle;
    always @(posedge vout_clk or negedge reset_n) begin
        if (!reset_n) begin
            hdmi_seen <= 1'b0;
            hdmi_toggle <= 1'b0;
        end else if (hdmi_vsync) begin
            hdmi_seen <= 1'b0;
        end else if (hdmi_pixel_valid && !hdmi_seen) begin
            hdmi_seen <= 1'b1;
            hdmi_toggle <= ~hdmi_toggle;
        end
    end

    reg [2:0] cam_sync, hdmi_sync, ack_sync;
    wire cam_first = cam_sync[2] ^ cam_sync[1];
    wire hdmi_first = hdmi_sync[2] ^ hdmi_sync[1];

    // Count the selected sensor's VSYNC itself, regardless of whether a DDR
    // bank accepted the frame. A ten-second gate gives 0.1 fps resolution.
    reg [2:0] raw_vsync_sync;
    wire raw_vsync_rise = raw_vsync_sync[1] && !raw_vsync_sync[2];
    reg raw_measure_running;
    reg [30:0] raw_measure_cycle;
    reg [11:0] raw_vsync_count;
    reg [11:0] raw_fps_tenths_ddr;
    reg raw_rate_valid_ddr;

    // core_clk is 125 MHz. One tick is 0.1 ms; 32 bits wrap after about
    // five days, and modular subtraction remains valid for a frame latency.
    reg [2:0] output_vsync_sync;
    wire output_vsync_rise = output_vsync_sync[1] && !output_vsync_sync[2];
    reg [3:0] output_measure_seconds;
    reg [11:0] output_scan_count;
    reg [11:0] output_refresh_tenths_ddr;
    reg output_refresh_valid_ddr;
    reg [13:0] tick_div;
    reg [31:0] ticks;
    reg [13:0] second_div;
    reg [7:0] unique_count;
    reg [7:0] raw_count, render_count;
    reg [7:0] raw_fps_ddr, render_fps_ddr;
    reg [15:0] next_frame_id;
    reg [15:0] last_display_id;
    reg last_display_seen;
    reg [15:0] raw_id [0:2];
    reg [31:0] raw_tick [0:2];
    reg [31:0] raw_complete_tick [0:2];
    reg [13:0] raw_capture_tenth [0:2];
    reg        raw_valid [0:2];
    reg raw_complete_valid[0:2];
    reg [15:0] corrected_id [0:1];
    reg [31:0] corrected_tick [0:1];
    reg [31:0] corrected_grant_tick [0:1];
    reg [31:0] corrected_done_tick [0:1];
    reg [13:0] corrected_capture_tenth [0:1];
    reg [13:0] corrected_queue_tenth [0:1];
    reg [13:0] corrected_render_tenth [0:1];
    reg        corrected_valid [0:1];
    reg corrected_started[0:1],corrected_displayed[0:1],corrected_counted[0:1];
    reg corrected_early[0:1];reg [13:0] corrected_overlap[0:1];
    reg [13:0] overlap_tenth_ddr;reg [31:0] repeat_frames;
    reg [13:0] latency_tenth_ms_ddr;
    reg [13:0] capture_tenth_ms_ddr;
    reg [13:0] queue_tenth_ms_ddr;
    reg [13:0] render_tenth_ms_ddr;
    reg [13:0] display_tenth_ms_ddr;
    reg latency_valid_ddr;
    reg [7:0] corrected_fps_ddr;
    reg [120:0] payload_ddr;
    reg send_toggle;
    reg ack_toggle;
    reg [2:0] send_sync;
    integer i;
    assign diagnostics_ddr_o={{20'd0,output_refresh_tenths_ddr},{18'd0,latency_tenth_ms_ddr},repeat_frames,{24'd0,corrected_fps_ddr},{24'd0,render_fps_ddr},{24'd0,raw_fps_ddr},{20'd0,raw_fps_tenths_ddr},{18'd0,overlap_tenth_ddr},{18'd0,display_tenth_ms_ddr},{18'd0,render_tenth_ms_ddr},{18'd0,queue_tenth_ms_ddr},{18'd0,capture_tenth_ms_ddr}};
    wire [31:0] elapsed_tenths = ticks - corrected_tick[display_bank];
    pane_latency_meter u_pane_latency (
        .ddr_clk(ddr_clk),.pixel_clk(vout_clk),.reset_n(reset_n),
        .ticks_i(ticks),.source_tick_i(corrected_tick[display_bank]),
        .source_id_i(corrected_id[display_bank]),
        .metadata_valid_i(display_valid && display_bank<2 &&
            (corrected_valid[display_bank] || (display_live_i && corrected_started[display_bank]))),
        .mode_i(display_mode_i),.view_i(display_view_i),.state_i(processing_state_i),
        .vsync_i(hdmi_vsync),.de_i(hdmi_de),.content_de_i(hdmi_pixel_valid),
        .first_tenths_o(pane_first_tenths_o),.end_tenths_o(pane_end_tenths_o),
        .first_valid_o(pane_first_valid_o),.end_valid_o(pane_end_valid_o),.layout_o(pane_layout_o)
    );

    function [13:0] clip_tenths;
        input [31:0] value;
        begin
            clip_tenths = value > 32'd9999 ? 14'd9999 : value[13:0];
        end
    endfunction

    always @(posedge ddr_clk or negedge reset_n) begin
        if (!reset_n) begin
            output_vsync_sync <= 3'b000;
            output_measure_seconds <= 4'd0;
            output_scan_count <= 12'd0;
            output_refresh_tenths_ddr <= 12'd0;
            output_refresh_valid_ddr <= 1'b0;
            cam_sync <= 3'b000;
            hdmi_sync <= 3'b000;
            ack_sync <= 3'b000;
            raw_vsync_sync <= 3'b000;
            raw_measure_running <= 1'b0;
            raw_measure_cycle <= 31'd0;
            raw_vsync_count <= 12'd0;
            raw_fps_tenths_ddr <= 12'd0;
            raw_rate_valid_ddr <= 1'b0;
            tick_div <= 14'd0;
            ticks <= 32'd0;
            second_div <= 14'd0;
            unique_count <= 8'd0;
            raw_count <= 8'd0;
            render_count <= 8'd0;
            raw_fps_ddr <= 8'd0;
            render_fps_ddr <= 8'd0;
            next_frame_id <= 16'd0;
            last_display_id <= 16'd0;
            last_display_seen <= 1'b0;
            latency_tenth_ms_ddr <= 14'd0;
            capture_tenth_ms_ddr <= 14'd0;overlap_tenth_ddr<=0;repeat_frames<=0;new_display_pulse_o<=0;first_before_done_o<=0;
            queue_tenth_ms_ddr <= 14'd0;
            render_tenth_ms_ddr <= 14'd0;
            display_tenth_ms_ddr <= 14'd0;
            latency_valid_ddr <= 1'b0;
            corrected_fps_ddr <= 8'd0;
            payload_ddr <= 121'd0;
            send_toggle <= 1'b0;
            for (i = 0; i < 3; i = i + 1) begin
                raw_id[i] <= 16'd0;
                raw_tick[i] <= 32'd0;
                raw_complete_tick[i] <= 32'd0;
                raw_capture_tenth[i] <= 14'd0;
                raw_valid[i] <= 1'b0;raw_complete_valid[i]<=0;
            end
            for (i = 0; i < 2; i = i + 1) begin
                corrected_id[i] <= 16'd0;
                corrected_tick[i] <= 32'd0;
                corrected_grant_tick[i] <= 32'd0;
                corrected_done_tick[i] <= 32'd0;
                corrected_capture_tenth[i] <= 14'd0;
                corrected_queue_tenth[i] <= 14'd0;
                corrected_render_tenth[i] <= 14'd0;
                corrected_valid[i] <= 1'b0;corrected_early[i]<=0;corrected_overlap[i]<=0;
                corrected_started[i]<=0;corrected_displayed[i]<=0;corrected_counted[i]<=0;
            end
        end else begin
            new_display_pulse_o<=0;
            output_vsync_sync <= {output_vsync_sync[1:0], hdmi_vsync};
            if (tick_div == 14'd12499 && second_div == 14'd9999
                && output_measure_seconds == 4'd9) begin
                output_refresh_tenths_ddr <= output_scan_count
                    + {11'd0, output_vsync_rise && output_scan_count != 12'hfff};
                output_refresh_valid_ddr <= 1'b1;
                output_scan_count <= 12'd0;
                output_measure_seconds <= 4'd0;
            end else begin
                if (output_vsync_rise && output_scan_count != 12'hfff)
                    output_scan_count <= output_scan_count + 1'b1;
                if (tick_div == 14'd12499 && second_div == 14'd9999)
                    output_measure_seconds <= output_measure_seconds + 1'b1;
            end
            cam_sync <= {cam_sync[1:0], cam_toggle};
            hdmi_sync <= {hdmi_sync[1:0], hdmi_toggle};
            ack_sync <= {ack_sync[1:0], ack_toggle};
            raw_vsync_sync <= {raw_vsync_sync[1:0], camera_vsync};
            if (!raw_measure_running) begin
                if (raw_vsync_rise) begin
                    raw_measure_running <= 1'b1;
                    raw_measure_cycle <= 31'd0;
                    raw_vsync_count <= 12'd0;
                end
            end else if (raw_measure_cycle == CAMERA_MEASURE_CYCLES - 1) begin
                raw_measure_cycle <= 31'd0;
                raw_fps_tenths_ddr <= raw_vsync_count + {11'd0, raw_vsync_rise};
                raw_rate_valid_ddr <= 1'b1;
                raw_vsync_count <= 12'd0;
            end else begin
                raw_measure_cycle <= raw_measure_cycle + 1'b1;
                if (raw_vsync_rise && raw_vsync_count != 12'hfff)
                    raw_vsync_count <= raw_vsync_count + 1'b1;
            end
            if (tick_div == 14'd12499) begin
                tick_div <= 14'd0;
                ticks <= ticks + 1'b1;
                if (second_div == 14'd9999) begin
                    second_div <= 14'd0;
                    corrected_fps_ddr <= unique_count;
                    raw_fps_ddr <= raw_count;
                    render_fps_ddr <= render_count;
                    unique_count <= 8'd0;
                    raw_count <= 8'd0;
                    render_count <= 8'd0;
                end else begin
                    second_div <= second_div + 1'b1;
                end
            end else begin
                tick_div <= tick_div + 1'b1;
            end

            if (camera_accept && camera_bank < 3)begin
                raw_valid[camera_bank] <= 1'b0;raw_complete_valid[camera_bank]<=0;end
            if (camera_frame_complete) begin
                if (raw_count != 8'hff)
                    raw_count <= raw_count + 1'b1;
                if (camera_bank < 3 && raw_valid[camera_bank]) begin
                    raw_complete_valid[camera_bank]<=1;
                    raw_complete_tick[camera_bank] <= ticks;
                    raw_capture_tenth[camera_bank] <=
                        clip_tenths(ticks - raw_tick[camera_bank]);
                end
            end
            if (render_done && render_count != 8'hff)
                render_count <= render_count + 1'b1;
            if (cam_first && camera_bank < 3) begin
                raw_id[camera_bank] <= next_frame_id;
                raw_tick[camera_bank] <= ticks;
                raw_valid[camera_bank] <= 1'b1;
                next_frame_id <= next_frame_id + 1'b1;
            end
            if (render_grant && render_source_bank < 3 &&
                render_destination_bank < 2) begin
                corrected_id[render_destination_bank] <= raw_id[render_source_bank];
                corrected_tick[render_destination_bank] <= raw_tick[render_source_bank];
                corrected_capture_tenth[render_destination_bank] <=
                    raw_capture_tenth[render_source_bank];
                corrected_queue_tenth[render_destination_bank] <=
                    raw_complete_valid[render_source_bank]?clip_tenths(ticks - raw_complete_tick[render_source_bank]):14'd0;
                corrected_early[render_destination_bank]<=!raw_complete_valid[render_source_bank];
                corrected_grant_tick[render_destination_bank] <= ticks;
                corrected_valid[render_destination_bank] <= 1'b0;
                corrected_started[render_destination_bank]<=raw_valid[render_source_bank];
                corrected_displayed[render_destination_bank]<=0;corrected_counted[render_destination_bank]<=0;
            end
            if (render_done && render_destination_bank < 2 &&
                render_source_bank < 3) begin
                corrected_done_tick[render_destination_bank] <= ticks;
                corrected_capture_tenth[render_destination_bank]<=raw_capture_tenth[render_source_bank];
                corrected_overlap[render_destination_bank]<=corrected_early[render_destination_bank]?clip_tenths(raw_complete_tick[render_source_bank]-corrected_grant_tick[render_destination_bank]):14'd0;
                corrected_render_tenth[render_destination_bank] <=
                    clip_tenths(ticks - corrected_grant_tick[render_destination_bank]);
                corrected_valid[render_destination_bank] <= raw_valid[render_source_bank];
                // Complete the diagnostic fields of a frame already scanned
                // early. Its first-pixel timestamp remains the original value.
                if(corrected_displayed[render_destination_bank]&&display_valid&&display_bank==render_destination_bank)begin
                    capture_tenth_ms_ddr<=raw_capture_tenth[render_source_bank];
                    render_tenth_ms_ddr<=clip_tenths(ticks-corrected_grant_tick[render_destination_bank]);
                    overlap_tenth_ddr<=corrected_early[render_destination_bank]?clip_tenths(raw_complete_tick[render_source_bank]-corrected_grant_tick[render_destination_bank]):14'd0;
                end
                // A partially shown frame counts as a successful new frame
                // only after its capture and corrected archive both succeed.
                if(corrected_displayed[render_destination_bank]&&!corrected_counted[render_destination_bank]&&raw_valid[render_source_bank])begin
                    corrected_counted[render_destination_bank]<=1;
                    if(unique_count!=8'hff)unique_count<=unique_count+1'b1;
                end
            end
            if (render_failed && render_destination_bank < 2)begin
                corrected_valid[render_destination_bank] <= 1'b0;
                corrected_started[render_destination_bank]<=0;
            end

            if (hdmi_first && display_valid && display_bank < 2 &&
                (corrected_valid[display_bank]||((display_live_i===1'b1)&&corrected_started[display_bank])) &&
                (!last_display_seen || corrected_id[display_bank] != last_display_id)) begin
                last_display_id <= corrected_id[display_bank];new_display_pulse_o<=1;
                first_before_done_o<=!corrected_valid[display_bank];
                corrected_displayed[display_bank]<=1;
                overlap_tenth_ddr<=corrected_valid[display_bank]?corrected_overlap[display_bank]:14'd0;
                last_display_seen <= 1'b1;
                latency_tenth_ms_ddr <= clip_tenths(elapsed_tenths);
                capture_tenth_ms_ddr <= corrected_valid[display_bank]?corrected_capture_tenth[display_bank]:14'd0;
                queue_tenth_ms_ddr <= corrected_queue_tenth[display_bank];
                render_tenth_ms_ddr <= corrected_valid[display_bank]?corrected_render_tenth[display_bank]:14'd0;
                display_tenth_ms_ddr <=
                    corrected_valid[display_bank]?clip_tenths(ticks - corrected_done_tick[display_bank]):14'd0;
                latency_valid_ddr <= 1'b1;
                if (corrected_valid[display_bank]&&!corrected_counted[display_bank]&&unique_count != 8'hff)begin
                    unique_count <= unique_count + 1'b1;
                    corrected_counted[display_bank]<=1;
                end
            end
            if(hdmi_first&&display_valid&&display_bank<2&&(corrected_valid[display_bank]||((display_live_i===1'b1)&&corrected_started[display_bank]))&&last_display_seen&&corrected_id[display_bank]==last_display_id)repeat_frames<=repeat_frames+1'b1;
            // Stable-data toggle/acknowledge transfer to the HDMI clock.
            if (ack_sync[2] == send_toggle &&
                payload_ddr != {latency_valid_ddr, latency_tenth_ms_ddr,
                                capture_tenth_ms_ddr, queue_tenth_ms_ddr,
                                render_tenth_ms_ddr, display_tenth_ms_ddr,
                                corrected_fps_ddr,
                                raw_rate_valid_ddr, raw_fps_tenths_ddr,
                                raw_fps_ddr, render_fps_ddr,
                                output_refresh_valid_ddr, output_refresh_tenths_ddr}) begin
                payload_ddr <= {latency_valid_ddr, latency_tenth_ms_ddr,
                                capture_tenth_ms_ddr, queue_tenth_ms_ddr,
                                render_tenth_ms_ddr, display_tenth_ms_ddr,
                                corrected_fps_ddr,
                                raw_rate_valid_ddr, raw_fps_tenths_ddr,
                                raw_fps_ddr, render_fps_ddr,
                                output_refresh_valid_ddr, output_refresh_tenths_ddr};
                send_toggle <= ~send_toggle;
            end
        end
    end

    reg [120:0] payload_pixel;
    always @(posedge vout_clk or negedge reset_n) begin
        if (!reset_n) begin
            send_sync <= 3'b000;
            ack_toggle <= 1'b0;
            payload_pixel <= 121'd0;
        end else begin
            send_sync <= {send_sync[1:0], send_toggle};
            if (send_sync[2] != ack_toggle) begin
                payload_pixel <= payload_ddr;
                ack_toggle <= send_sync[2];
            end
        end
    end

    assign {latency_valid, latency_tenth_ms,
            capture_tenth_ms, queue_tenth_ms,
            render_tenth_ms, display_tenth_ms, corrected_fps,
            camera_rate_valid, camera_fps_tenths,
            raw_fps, render_fps, output_refresh_valid, output_refresh_tenths} = payload_pixel;
endmodule

`timescale 1ns/1ps

// Measures raster endpoints of each displayed pane against the SAME source
// frame's first accepted camera pixel. The DDR bank metadata is held from
// vertical blanking through the complete scan. Event toggles settle in the
// DDR domain long before the next bank publication. Black mapped pixels count;
// layout letterboxes and OSD pixels do not. No additional image memory.
module pane_latency_meter #(
    parameter integer H_ACTIVE=1280, V_ACTIVE=720
) (
    input wire ddr_clk, pixel_clk, reset_n,
    input wire [31:0] ticks_i, source_tick_i,
    input wire [15:0] source_id_i,
    input wire metadata_valid_i,
    input wire [1:0] mode_i,
    input wire [2:0] view_i,
    input wire [1:0] state_i,
    input wire vsync_i, de_i, content_de_i,
    output wire [55:0] first_tenths_o, end_tenths_o,
    output wire [3:0] first_valid_o, end_valid_o,
    output wire [6:0] layout_o
);
    localparam integer HALF_H=H_ACTIVE/2, HALF_V=V_ACTIVE/2;
    localparam integer COMP_TOP=V_ACTIVE/4;
    reg [11:0] x,y;
    reg [1:0] mode_meta,mode_sync;
    reg [2:0] view_meta,view_sync;
    reg [3:0] first_toggle,end_toggle;
    reg scan_toggle,vsync_d;
    reg [3:0] first_mask,end_mask;
    always @* begin
        first_mask=0;end_mask=0;
        if(mode_sync==2)begin
            if(y==COMP_TOP)begin
                if(x==0)first_mask=4'b0001;
                if(x==HALF_H)first_mask=4'b0010;
            end
            if(y==COMP_TOP+HALF_V-1)begin
                if(x==HALF_H-1)end_mask=4'b0001;
                if(x==H_ACTIVE-1)end_mask=4'b0010;
            end
        end else if(mode_sync==1&&view_sync!=5)begin
            if(x==H_ACTIVE/4&&y==COMP_TOP)first_mask=4'b0001;
            if(x==H_ACTIVE*3/4-1&&y==COMP_TOP+HALF_V-1)end_mask=4'b0001;
        end else if(mode_sync==1&&view_sync==5)begin
            if(y==0)begin
                if(x==0)first_mask=4'b0001;
                if(x==HALF_H)first_mask=4'b0010;
            end
            if(y==HALF_V)begin
                if(x==0)first_mask=4'b0100;
                if(x==HALF_H)first_mask=4'b1000;
            end
            if(y==HALF_V-1)begin
                if(x==HALF_H-1)end_mask=4'b0001;
                if(x==H_ACTIVE-1)end_mask=4'b0010;
            end
            if(y==V_ACTIVE-1)begin
                if(x==HALF_H-1)end_mask=4'b0100;
                if(x==H_ACTIVE-1)end_mask=4'b1000;
            end
        end else if(mode_sync==0 || mode_sync==3)begin
            if(x==0 && y==0)first_mask=4'b0001;
            if(x==H_ACTIVE-1 && y==V_ACTIVE-1)end_mask=4'b0001;
        end
    end
    always @(posedge pixel_clk or negedge reset_n)begin
        if(!reset_n)begin
            x<=0;y<=0;mode_meta<=0;mode_sync<=0;view_meta<=0;view_sync<=0;
            first_toggle<=0;end_toggle<=0;scan_toggle<=0;vsync_d<=0;
        end else begin
            vsync_d<=vsync_i;
            if(vsync_i&&!vsync_d)scan_toggle<=~scan_toggle;
            mode_meta<=mode_i;mode_sync<=mode_meta;
            view_meta<=view_i;view_sync<=view_meta;
            if(vsync_i)begin x<=0;y<=0;end
            else if(de_i)begin
                if(x==H_ACTIVE-1)begin x<=0;y<=y+1'b1;end
                else x<=x+1'b1;
                if(content_de_i)begin
                    first_toggle<=first_toggle^first_mask;
                    end_toggle<=end_toggle^end_mask;
                end
            end
        end
    end

    reg [3:0] first_meta,first_sync,first_old,end_meta,end_sync,end_old;
    wire [3:0] first_event=first_sync^first_old;
    wire [3:0] end_event=end_sync^end_old;
    reg [15:0] held_id;
    reg [6:0] held_layout;
    reg [1:0] state_meta_ddr,state_sync_ddr;
    reg held_valid;
    reg [55:0] first_ddr,end_ddr;
    reg [3:0] first_valid_ddr,end_valid_ddr;
    reg [3:0] end_eligible;
    reg [2:0] scan_sync;
    wire scan_start=scan_sync[2]^scan_sync[1];
    wire [31:0] elapsed=ticks_i-source_tick_i;
    wire [13:0] clipped=elapsed>9999?14'd9999:elapsed[13:0];
    wire new_identity=!held_valid || held_id!=source_id_i || held_layout!={mode_i,view_i,state_sync_ddr};
    integer k;
    always @(posedge ddr_clk or negedge reset_n)begin
        if(!reset_n)begin
            first_meta<=0;first_sync<=0;first_old<=0;end_meta<=0;end_sync<=0;end_old<=0;
            held_id<=0;held_layout<=0;held_valid<=0;state_meta_ddr<=0;state_sync_ddr<=0;
            first_ddr<=0;end_ddr<=0;first_valid_ddr<=0;end_valid_ddr<=0;end_eligible<=0;scan_sync<=0;
        end else begin
            scan_sync<={scan_sync[1:0],scan_toggle};
            if(scan_start)end_eligible<=0;
            state_meta_ddr<=state_i;state_sync_ddr<=state_meta_ddr;
            first_meta<=first_toggle;first_sync<=first_meta;first_old<=first_sync;
            end_meta<=end_toggle;end_sync<=end_meta;end_old<=end_sync;
            if(!metadata_valid_i)begin
                held_valid<=0;first_valid_ddr<=0;end_valid_ddr<=0;end_eligible<=0;
            end else if(new_identity)begin
                held_valid<=1;held_id<=source_id_i;held_layout<={mode_i,view_i,state_sync_ddr};
                first_valid_ddr<=0;end_valid_ddr<=0;end_eligible<=0;
            end else begin
                for(k=0;k<4;k=k+1)begin
                    // Freeze the FIRST scan of this source/layout. A repeated
                    // 60 Hz scan must not add 16.7 ms to a 30 fps source frame.
                    if(first_event[k] && !first_valid_ddr[k])begin
                        first_ddr[k*14+:14]<=clipped;first_valid_ddr[k]<=1;end_eligible[k]<=1;
                    end
                    if(end_event[k] && first_valid_ddr[k] && end_eligible[k] && !end_valid_ddr[k])begin
                        end_ddr[k*14+:14]<=clipped;end_valid_ddr[k]<=1;end_eligible[k]<=0;
                    end
                end
            end
        end
    end

    // Stable-data request/acknowledge transfer, not independent synchronizers
    // on binary time values. OSD then latches one complete bundle in VSYNC.
    reg [126:0] payload_ddr,payload_pixel;
    wire [126:0] current_payload={held_layout,first_valid_ddr,end_valid_ddr,first_ddr,end_ddr};
    reg send_toggle,ack_toggle;
    reg [2:0] ack_sync,send_sync;
    always @(posedge ddr_clk or negedge reset_n)begin
        if(!reset_n)begin ack_sync<=0;payload_ddr<=0;send_toggle<=0;end
        else begin
            ack_sync<={ack_sync[1:0],ack_toggle};
            if(ack_sync[2]==send_toggle && payload_ddr!=current_payload)begin
                payload_ddr<=current_payload;send_toggle<=~send_toggle;
            end
        end
    end
    always @(posedge pixel_clk or negedge reset_n)begin
        if(!reset_n)begin send_sync<=0;ack_toggle<=0;payload_pixel<=0;end
        else begin
            send_sync<={send_sync[1:0],send_toggle};
            if(send_sync[2]!=ack_toggle)begin
                payload_pixel<=payload_ddr;ack_toggle<=send_sync[2];
            end
        end
    end
    assign {layout_o,first_valid_o,end_valid_o,first_tenths_o,end_tenths_o}=payload_pixel;
endmodule

// Passive minimum-pixel observer. The exhaustive static profile selects the
// minimizer of output-raster position minus the latest source dependency.
// This identity is valid only while output uses the same recovered RX clock.
// Actual source and output events, not a nominal frame/geometry subtraction,
// are timestamped against the common 1us counter driven by 125 MHz. One 36K block stores twelve
// events for each of eight input IDs; full IDs reject overwritten/repeated tags.
module minimum_pixel_latency_meter(
 input wire clock,reset_n,rx_pixel_clk,pixel_clk,pixel_reset_n,
 input wire rx_vs_i,rx_de_i,source_qualified_i,
 input wire [31:0] input_frame_id_async_i,
 input wire following_i,eligible_i,vs_i,de_i,content_i,
 input wire [31:0] output_frame_id_async_i,
 input wire [1:0] mode_async_i,
 input wire [2:0] view_async_i,
 output reg [16:0] minimum_us_o,
 output reg minimum_valid_o,
 output reg [6:0] minimum_layout_o
);
 `include "source/design_fisheye_5frame_720p60_pipeline/data/minimum_pixel_profile.vh"
 reg [31:0] timer,timer_gray;
 reg [6:0] timer_divider;
 always @(posedge clock or negedge reset_n)begin
  if(!reset_n)begin timer<=0;timer_gray<=0;timer_divider<=0;end
  else if(timer_divider==124)begin timer_divider<=0;timer<=timer+1'b1;timer_gray<=((timer+1'b1)>>1)^(timer+1'b1);end
  else timer_divider<=timer_divider+1'b1;
 end
 reg [31:0] rx_time_meta,rx_time_sync,out_time_meta,out_time_sync;
 wire [31:0] rx_time,out_time;
 genvar bit_index;
 generate for(bit_index=0;bit_index<32;bit_index=bit_index+1)begin: time_decode
  assign rx_time[bit_index]=^rx_time_sync[31:bit_index];
  assign out_time[bit_index]=^out_time_sync[31:bit_index];
 end endgenerate
 reg [31:0] input_id_meta,input_id_sync,held_input_id;
 reg [1:0] qualified;
 reg rx_de_d,rx_vs_d,rx_seen,rx_bad;
 reg [10:0] rx_x,rx_y;
 reg [15:0] rx_cycle,last_line_cycle;
 reg [6:0] good_lines;
 always @(posedge rx_pixel_clk or negedge reset_n)begin
  if(!reset_n)begin
   rx_time_meta<=0;rx_time_sync<=0;input_id_meta<=0;input_id_sync<=0;held_input_id<=0;
   qualified<=0;rx_de_d<=0;rx_vs_d<=0;rx_seen<=0;rx_bad<=1;rx_x<=0;rx_y<=0;
   rx_cycle<=0;last_line_cycle<=0;good_lines<=0;
  end else begin
   rx_time_meta<=timer_gray;rx_time_sync<=rx_time_meta;
   input_id_meta<=input_frame_id_async_i;input_id_sync<=input_id_meta;
   qualified<={qualified[0],source_qualified_i};
   rx_de_d<=rx_de_i;rx_vs_d<=rx_vs_i;rx_cycle<=rx_cycle+1'b1;
   if(!qualified[1])begin rx_seen<=0;rx_bad<=1;end
   else if(rx_vs_i&&!rx_vs_d)begin rx_seen<=1;rx_bad<=0;rx_x<=0;rx_y<=0;good_lines<=0;end
   else if(!rx_vs_i&&rx_seen)begin
    if(rx_de_i)begin
     rx_x<=rx_x+1'b1;
     if(rx_x>=1280||rx_y>=720)rx_bad<=1;
     if(!rx_de_d)begin
      last_line_cycle<=rx_cycle;
      if(rx_y==0)held_input_id<=input_id_sync;
      else if(rx_cycle-last_line_cycle!=16'd1650)rx_bad<=1;
      else if(good_lines!=127)good_lines<=good_lines+1'b1;
     end
    end else if(rx_de_d)begin
     if(rx_x!=1280)rx_bad<=1;
     rx_x<=0;rx_y<=rx_y+1'b1;
    end
   end
  end
 end
 reg [3:0] write_slot;
 reg write_match;
 integer slot;
 reg [21:0] source_point;
 always @*begin
  write_slot=0;write_match=0;source_point=0;
  for(slot=0;slot<MINIMUM_SOURCE_POINTS;slot=slot+1)begin
   source_point=minimum_source_point(slot);
   if(rx_x==source_point[21:11]&&rx_y==source_point[10:0])begin write_slot=slot;write_match=1;end
  end
 end
 wire stamp_write=rx_de_i&&rx_seen&&!rx_vs_i&&!rx_bad&&qualified[1]&&good_lines>=2&&write_match;
 wire [8:0] write_address={2'b0,held_input_id[2:0],write_slot};
 reg [31:0] output_id_meta,output_id_sync;
 reg [1:0] mode_meta,mode_sync,allowed_sync,follow_sync;
 reg [2:0] view_meta,view_sync;
 reg [10:0] x,y;
 reg vs_d;
 wire [3:0] profile={mode_sync==2,view_sync};
 wire [24:0] output_point=minimum_output_point(profile);
 wire match_output=de_i&&content_i&&mode_sync!=0&&
    x==output_point[20:10]&&y=={1'b0,output_point[9:0]};
 wire read_stamp=match_output&&allowed_sync[1]&&follow_sync[1];
 wire [8:0] read_address={2'b0,output_id_sync[2:0],output_point[24:21]};
 wire [71:0] stamp;
 ipm2l_sdpram_v1_10_wr_fram_buf #(
  .c_CAS_MODE("36K"),.c_WR_ADDR_WIDTH(9),.c_WR_DATA_WIDTH(72),
  .c_RD_ADDR_WIDTH(9),.c_RD_DATA_WIDTH(72),.c_OUTPUT_REG(0),
  .c_WR_CLK_EN(1),.c_RD_CLK_EN(1),.c_RESET_TYPE("SYNC")
 ) timestamps(
  .wr_addr(write_address),.wr_data({7'd0,1'b1,held_input_id,rx_time}),.wr_en(stamp_write),
  .wr_clk(rx_pixel_clk),.wr_clk_en(stamp_write),.wr_rst(!reset_n),
  .wr_byte_en(8'hff),.wr_addr_strobe(1'b0),
  .rd_addr(read_address),.rd_data(stamp),.rd_clk(pixel_clk),.rd_clk_en(read_stamp),
  .rd_rst(!pixel_reset_n),.rd_oce(1'b1),.rd_addr_strobe(1'b0));
 reg pending;
 reg [31:0] event_time,event_id;
 reg [6:0] event_layout;
 wire [31:0] elapsed=event_time-stamp[31:0];
 always @(posedge pixel_clk or negedge pixel_reset_n)begin
  if(!pixel_reset_n)begin
   out_time_meta<=0;out_time_sync<=0;output_id_meta<=0;output_id_sync<=0;
   mode_meta<=0;mode_sync<=0;view_meta<=0;view_sync<=0;allowed_sync<=0;follow_sync<=0;
   x<=0;y<=0;vs_d<=0;pending<=0;event_time<=0;event_id<=0;event_layout<=0;
   minimum_us_o<=0;minimum_valid_o<=0;minimum_layout_o<=0;
  end else begin
   out_time_meta<=timer_gray;out_time_sync<=out_time_meta;
   output_id_meta<=output_frame_id_async_i;output_id_sync<=output_id_meta;
   mode_meta<=mode_async_i;mode_sync<=mode_meta;view_meta<=view_async_i;view_sync<=view_meta;
   allowed_sync<={allowed_sync[0],eligible_i};follow_sync<={follow_sync[0],following_i};
   vs_d<=vs_i;pending<=read_stamp;
   if(vs_i&&!vs_d)begin x<=0;y<=0;minimum_valid_o<=0;pending<=0;end
   else if(de_i)begin
    if(x==1279)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
   end
   if(!allowed_sync[1]||!follow_sync[1])begin minimum_valid_o<=0;pending<=0;end
   else begin
    if(read_stamp)begin event_time<=out_time;event_id<=output_id_sync;event_layout<={mode_sync,view_sync,2'b00};end
    if(pending)begin
     minimum_valid_o<=0;
     if(stamp[64]&&stamp[63:32]==event_id&&elapsed<=32'd99999)begin
      // Gray changes only once per microsecond. With a shared recovered
      // clock the two equal synchronizer delays cancel. Display resolution
      // and endpoint quantization are 1us; no arithmetic latency is omitted.
      minimum_us_o<=elapsed[16:0];minimum_valid_o<=1;minimum_layout_o<=event_layout;
     end
    end
   end
  end
 end
endmodule
