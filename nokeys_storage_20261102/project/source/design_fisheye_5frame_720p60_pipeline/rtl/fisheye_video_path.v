`timescale 1ns/1ps
`include "source/design_fisheye_5frame_720p60_pipeline/data/cutthrough_limits.vh"
`include "source/design_fisheye_5frame_720p60_pipeline/data/reverse_capture_limits.vh"

// Camera raw-frame capture, tile renderer and corrected-frame HDMI reader.
// This module replaces only the fram_buf instance in the copied top-level;
// the reference HDMI, camera and DDR IP source files are not modified.
module fisheye_video_path #(
    parameter integer CTRL_ADDR_WIDTH = 28,
    parameter integer MEM_DQ_WIDTH = 32,
    parameter integer H_NUM = 1280,
    parameter integer V_NUM = 720,
    parameter integer PIX_WIDTH = 16,
    parameter integer SOURCE_CAPTURE_REVERSE = 0,
    parameter integer MEASURE_OUTPUT_FEEDBACK = 0
) (
    input wire source_reverse_i,input wire capture_abort_i,output wire capture_drained_o,
    input wire streaming_enabled_i,
    input wire certified_base_phase_i,phase_locked_i,
    output reg sync_ready_toggle_o,output reg [23:0] sync_ready_cycles_o,
    output wire [7:0] hdmi_admission_status_o,
    output wire [20:0] hdmi_stability_o,output reg hdmi_stability_valid_o,
    input  wire                         vin_clk,
    input  wire                         wr_fsync,
    input  wire                         wr_en,
    input  wire [PIX_WIDTH-1:0]         wr_data,
    output reg                          init_done,
    input  wire                         ddr_clk,
    input  wire                         ddr_rstn,
    input  wire                         vout_clk,
    input  wire                         rd_fsync,
    input  wire                         rd_en,
    // Board top feeds the registered HDMI stream after Gamma/OSD. Standalone
    // regressions may retain the reader endpoint by leaving the parameter 0.
    input wire measure_vsync_i,measure_de_i,measure_content_i,measure_enhanced_i,
    output wire                         vout_de,
    output wire                         vout_content_de,
    output wire [PIX_WIDTH-1:0]         vout_data,
    input wire [2:0] requested_view_i,
    input wire stabilization_enable_i,pose_valid_i,
    input wire [31:0] pose_frame_i,pose_tick_i,hardware_tick_i,frame_id_i,frame_tick_i,
    input wire [287:0] pose_matrix_i,
    input wire [1439:0] pose_views_i,input wire pose_allviews_i,
    input wire [2:0] pose_view_i,input wire [7:0] pose_sequence_i,input wire pose_tagged_i,
    output wire display_stabilized_o,output wire displayed_hdmi_o,
    output wire [1279:0] diagnostics_data_o,output wire diagnostics_valid_o,
    output wire [31:0] displayed_source_frame_o,displayed_source_tick_o,
    input wire [7:0] requested_seq_i,
    output wire [2:0] display_view_o,
    output wire [7:0] display_seq_o,
    input  wire [1:0]                   display_mode_i,
    output wire [1:0]                   display_mode_o,
    output wire [13:0]                  latency_tenth_ms_o,
    output wire                         latency_valid_o,
    output wire [55:0] pane_first_tenths_o,pane_end_tenths_o,
    output wire [3:0] pane_first_valid_o,pane_end_valid_o,
    output wire [6:0] pane_layout_o,
    output wire [13:0]                  capture_tenth_ms_o,
    output wire [13:0]                  queue_tenth_ms_o,
    output wire [13:0]                  render_tenth_ms_o,
    output wire [13:0]                  display_tenth_ms_o,
    output wire [7:0]                   corrected_fps_o,
    output wire [11:0]                  camera_fps_tenths_o,
    output wire                         camera_rate_valid_o,
    output wire [7:0]                   raw_fps_o,
    output wire [7:0]                   render_fps_o,
    output wire [11:0]                  output_refresh_tenths_o,
    output wire                         output_refresh_valid_o,
    // Calibration table loader interface in the DDR clock domain.
    input  wire                         cal_write_en_i,
    input  wire                         cal_table_select_i,
    input  wire [13:0]                  cal_write_addr_i,
    input  wire [47:0]                  cal_write_data_i,
    input  wire                         cal_commit_i,
    output wire                         calibration_loaded_o,
    output wire [CTRL_ADDR_WIDTH-1:0]   axi_awaddr,
    output wire [3:0]                   axi_awid,
    output wire [3:0]                   axi_awlen,
    output wire [2:0]                   axi_awsize,
    output wire [1:0]                   axi_awburst,
    input  wire                         axi_awready,
    output wire                         axi_awvalid,
    output wire [MEM_DQ_WIDTH*8-1:0]   axi_wdata,
    output wire [MEM_DQ_WIDTH-1:0]     axi_wstrb,
    input  wire                         axi_wlast,
    output wire                         axi_wvalid,
    input  wire                         axi_wready,
    input  wire [3:0]                   axi_bid,
    output wire [CTRL_ADDR_WIDTH-1:0]   axi_araddr,
    output wire [3:0]                   axi_arid,
    output wire [3:0]                   axi_arlen,
    output wire [2:0]                   axi_arsize,
    output wire [1:0]                   axi_arburst,
    output wire                         axi_arvalid,
    input  wire                         axi_arready,
    output wire                         axi_rready,
    input  wire [MEM_DQ_WIDTH*8-1:0]   axi_rdata,
    input  wire                         axi_rvalid,
    input  wire                         axi_rlast,
    input  wire [3:0]                   axi_rid
);
    // One 720p RGB565 frame needs 460800 32-bit words; 2^19 words
    // reserve 2 MiB for each of the five nonoverlapping DDR banks.
    localparam integer FRAME_ADDR_BITS = 19;
    localparam integer LEN_WIDTH = 32;

    wire camera_accept;
    wire [1:0] camera_write_bank;
    wire [1:0] render_source_bank;
    reg capture_enabled;
    wire camera_frame_start;
    wire pending_valid,pose_pending_ready,pose_render_ready;wire [1:0] pending_bank;
    reg pose_pending_ready_q;
    reg [1:0] pose_pending_bank_q;
    reg [2:0] pose_pending_view_q;reg [7:0] pose_pending_sequence_q;
    wire dynamic_request=(stabilization_enable_i===1'b1)&&display_mode_i!=0&&(requested_view_i==6||requested_view_i==7);
    wire pose_candidate_ready=pose_pending_ready_q&&pose_pending_bank_q==pending_bank&&
        pose_pending_view_q==requested_view_i&&pose_pending_sequence_q==requested_seq_i;
    wire [287:0] frame_pose;wire [1439:0] frame_views;wire frame_allviews;reg bank_stabilized[0:1];
    reg first_seen,first_toggle;reg [2:0] first_sync;
    always @(posedge vin_clk or negedge ddr_rstn)begin
      if(!ddr_rstn)begin first_seen<=0;first_toggle<=0;end
      else if(wr_fsync)first_seen<=0;
      else if(wr_en&&capture_enabled&&!first_seen)begin first_seen<=1;first_toggle<=~first_toggle;end
    end
    always @(posedge ddr_clk)if(!ddr_rstn)first_sync<=0;else first_sync<={first_sync[1:0],first_toggle};
    frame_pose_store u_frame_pose(.clock(ddr_clk),.reset_n(ddr_rstn),.hardware_tick_i(hardware_tick_i),
      .camera_accept_i(camera_accept),.camera_first_i(first_sync[2]^first_sync[1]),.camera_bank_i(camera_write_bank),
      .frame_id_i(frame_id_i),.frame_tick_i(frame_tick_i),.pose_valid_i(pose_valid_i),
      .pose_frame_i(pose_frame_i),.pose_tick_i(pose_tick_i),.pose_matrix_i(pose_matrix_i),
      .pose_views_i(pose_views_i),.pose_allviews_i(pose_allviews_i),
      .pose_view_i(pose_view_i),.pose_sequence_i(pose_sequence_i),.pose_tagged_i(pose_tagged_i),
      .requested_view_i(requested_view_i),.requested_sequence_i(requested_seq_i),
      .pending_bank_i(pending_bank),.render_bank_i(render_source_bank),
      .pending_ready_o(pose_pending_ready),.render_ready_o(pose_render_ready),.render_matrix_o(frame_pose),.render_views_o(frame_views),.render_allviews_o(frame_allviews));
    wire hdmi_frame_start;

    wire camera_drop;
    wire camera_write_active;

    wire render_grant;
    wire render_active;

    wire [1:0] render_destination_bank;
    wire display_valid;
    wire [1:0] display_bank;
    wire [1:0] display_raw_bank;
    wire render_busy;
    wire render_done;
    wire render_error;
    wire [5:0] render_error_reason;
    reg [2:0] bank_view[0:1];
    reg [7:0] bank_seq[0:1];
    reg [1:0] bank_mode[0:1];
    always @(posedge ddr_clk) begin
        if(!ddr_rstn) begin bank_view[0]<=6;bank_view[1]<=6;bank_seq[0]<=0;bank_seq[1]<=0;bank_mode[0]<=0;bank_mode[1]<=0;bank_stabilized[0]<=0;bank_stabilized[1]<=0;end
        else if(render_grant)begin
            bank_view[render_destination_bank]<=requested_view_i;
            bank_seq[render_destination_bank]<=requested_seq_i;
            bank_mode[render_destination_bank]<=display_mode_i;
            bank_stabilized[render_destination_bank]<=dynamic_request&&pose_render_ready;
        end
    end
    wire calibration_loaded;

    wire camera_ddr_wreq;
    wire [CTRL_ADDR_WIDTH-1:0] camera_ddr_waddr;
    wire [CTRL_ADDR_WIDTH-1:0] canonical_camera_waddr;
    capture_row_address #(.SOURCE_CAPTURE_REVERSE(SOURCE_CAPTURE_REVERSE)) capture_address (
        .reverse_i(source_reverse_i),.address_i(camera_ddr_waddr), .address_o(canonical_camera_waddr)
    );
    wire [LEN_WIDTH-1:0] camera_ddr_wr_len;
    wire camera_ddr_wrdy;
    wire camera_ddr_wdone;
    wire [MEM_DQ_WIDTH*8-1:0] camera_ddr_wdata;
    wire camera_ddr_wdata_req;
    wire camera_ddr_bac;
    wire display_ddr_rreq;
    wire [CTRL_ADDR_WIDTH-1:0] display_ddr_raddr;
    wire [LEN_WIDTH-1:0] display_ddr_rd_len;
    wire display_ddr_rrdy;
    wire display_ddr_rdone;
    wire [MEM_DQ_WIDTH*8-1:0] display_ddr_rdata;
    wire display_ddr_rdata_en;
    wire display_de;
    wire display_content_de;
    wire [PIX_WIDTH-1:0] display_pixel;

    wire [CTRL_ADDR_WIDTH-1:0] m0_awaddr;
    wire [3:0] m0_awid, m0_awlen;
    wire m0_awready, m0_awvalid;
    wire [MEM_DQ_WIDTH*8-1:0] m0_wdata;
    wire [MEM_DQ_WIDTH-1:0] m0_wstrb;
    wire m0_wready, m0_wlast;
    wire [CTRL_ADDR_WIDTH-1:0] m0_araddr;
    wire [3:0] m0_arid, m0_arlen;
    wire m0_arready, m0_arvalid;
    wire [MEM_DQ_WIDTH*8-1:0] m0_rdata;
    wire m0_rvalid, m0_rlast;
    wire [3:0] m0_rid;

    wire [27:0] m1_awaddr, m1_araddr;
    wire [3:0] m1_awid, m1_awlen, m1_arid, m1_arlen;
    wire m1_awready, m1_awvalid, m1_wready, m1_wlast;
    wire [255:0] m1_wdata;
    wire [31:0] m1_wstrb;
    wire m1_arready, m1_arvalid, m1_rvalid, m1_rlast;
    wire [255:0] m1_rdata;
    wire [3:0] m1_rid;

    wire camera_frame_complete;
    integer raw_index;
    wire [10:0] capture_committed;wire capture_failed;
    reg [10:0] raw_committed[0:2];reg [2:0] raw_complete,raw_failed;
    wire [543:0] render_counters;
    wire [383:0] metrics_ddr;wire metrics_new_display;
    wire first_before_done;
    reg [543:0] bank_counters[0:1];reg [31:0] raw_frame_ids[0:2],bank_frame_ids[0:1];
    reg [31:0] raw_frame_ticks[0:2],bank_frame_ticks[0:1];
    reg [10:0] bank_rows_committed[0:1];
    wire [10:0] render_rows_committed;
    wire render_progress,render_dependencies_ready;
    reg [159:0] bank_cache_stats[0:1];
    wire [159:0] render_cache_stats,source_cache_stats;
    assign render_cache_stats=source_cache_stats;
    wire display_live,display_fault,scan_failed;
    wire live_admit,admission_ready,admission_budget_exceeded,producer_fault;
    reg display_command_busy;
    wire selected_live=display_live&&render_active&&display_bank==render_destination_bank;
    wire native_render=bank_view[render_destination_bank]<5||bank_view[render_destination_bank]==6;
    wire [10:0] render_total_rows=native_render ? 11'd360 : 11'd720;
    function [10:0] static_source_limit;
        input [2:0] view;input reverse_order;
        begin
        if(reverse_order) begin case(view)
            0:static_source_limit=`REVERSE_LIMIT_VIEW0;
            1:static_source_limit=`REVERSE_LIMIT_VIEW1;
            2:static_source_limit=`REVERSE_LIMIT_VIEW2;
            3:static_source_limit=`REVERSE_LIMIT_VIEW3;
            4:static_source_limit=`REVERSE_LIMIT_VIEW4;
            5:static_source_limit=`REVERSE_LIMIT_VIEW5;
            6:static_source_limit=`REVERSE_LIMIT_VIEW6;
            default:static_source_limit=`REVERSE_LIMIT_VIEW7;
        endcase end else begin case(view)
            0:static_source_limit=`CUTTHROUGH_LIMIT_VIEW0;
            1:static_source_limit=`CUTTHROUGH_LIMIT_VIEW1;
            2:static_source_limit=`CUTTHROUGH_LIMIT_VIEW2;
            3:static_source_limit=`CUTTHROUGH_LIMIT_VIEW3;
            4:static_source_limit=`CUTTHROUGH_LIMIT_VIEW4;
            5:static_source_limit=`CUTTHROUGH_LIMIT_VIEW5;
            6:static_source_limit=`CUTTHROUGH_LIMIT_VIEW6;
            default:static_source_limit=`CUTTHROUGH_LIMIT_VIEW7;
        endcase end
        end
    endfunction
    reg [2:0] raw_reverse;
    wire static_geometry=!bank_stabilized[render_destination_bank]||bank_view[render_destination_bank]==0;
    wire source_for_live_ready,live_certificate;
    dynamic_scanout_guard dynamic_guard(
        .static_i(static_geometry),.raw_complete_i(raw_complete[render_source_bank]),
        .source_failed_i(raw_failed[render_source_bank]),.dependencies_ready_i(render_dependencies_ready),
        .committed_source_i(raw_committed[render_source_bank]),
        .static_source_limit_i(static_source_limit(bank_view[render_destination_bank],raw_reverse[render_source_bank])),
        .total_rows_i(render_total_rows),.committed_output_i(bank_rows_committed[render_destination_bank]),
        .mode_i(bank_mode[render_destination_bank]),.source_ready_o(source_for_live_ready),.certificate_o(live_certificate)
    );
    // Break the committed-row/geometry comparison -> display publication ->
    // render allocation -> capture allocation path. Readiness is monotonic
    // while its RAW bank is owned. Clear at every grant, and keep RAW failure
    // rejection immediate rather than delaying that safety condition.
    reg source_for_live_ready_q,live_certificate_q;
    always @(posedge ddr_clk)begin
        if(!ddr_rstn||render_grant||!render_active)begin source_for_live_ready_q<=0;live_certificate_q<=0;end
        else begin source_for_live_ready_q<=source_for_live_ready;live_certificate_q<=live_certificate;end
    end
    live_admission admission (
        .clock(ddr_clk),.reset_n(ddr_rstn),.frame_start_i(render_grant),.render_active_i(render_active),
        .source_ready_i(source_for_live_ready_q&&!raw_failed[render_source_bank]),.live_selected_i(selected_live),
        .total_rows_i(render_total_rows),.committed_rows_i(bank_rows_committed[render_destination_bank]),
        .mode_i(bank_mode[render_destination_bank]),.native_i(native_render),.certified_i(live_certificate_q&&!raw_failed[render_source_bank]),.progress_i(render_progress),
        .admit_o(admission_ready),.budget_exceeded_o(admission_budget_exceeded),.live_fault_o(producer_fault)
    );
    // The unchanged fixed BASE7 alone owns this precomputed envelope.
    wire baseline_fast=raw_reverse[render_source_bank]&&static_geometry&&
        bank_view[render_destination_bank]==7&&bank_mode[render_destination_bank]!=0&&bank_mode[render_destination_bank]!=2;
    wire baseline_admit,baseline_budget_fault;
    baseline_scanout_admission baseline_admission(
        .clock(ddr_clk),.reset_n(ddr_rstn),.frame_start_i(render_grant),
        .enabled_i(baseline_fast),.render_active_i(render_active),
        .source_rows_i(raw_committed[render_source_bank]),.source_complete_i(raw_complete[render_source_bank]),
        .source_failed_i(raw_failed[render_source_bank]),
        .output_rows_i(bank_rows_committed[render_destination_bank]),
        .admit_o(baseline_admit),.budget_fault_o(baseline_budget_fault));
    // The reverse-capture certificate is monotonic while this task owns its
    // source bank. Delay positive publication one clock, but retain immediate
    // RAW/budget fault rejection. This breaks the remaining camera-compatible
    // comparator -> display -> render -> capture allocation timing path.
    reg baseline_admit_q;
    always @(posedge ddr_clk)begin
      if(!ddr_rstn||render_grant||!render_active)baseline_admit_q<=0;
      else baseline_admit_q<=baseline_admit;
    end
    reg [1:0] streaming_sync,certified_phase_sync,phase_locked_sync;
    always @(posedge ddr_clk)begin
      if(!ddr_rstn)begin streaming_sync<=0;certified_phase_sync<=0;phase_locked_sync<=0;end
      else begin
        streaming_sync<={streaming_sync[0],streaming_enabled_i===1'b1};
        certified_phase_sync<={certified_phase_sync[0],certified_base_phase_i===1'b1};
        phase_locked_sync<={phase_locked_sync[0],phase_locked_i===1'b1};
      end
    end
    wire hdmi_stream_admit,hdmi_stream_fault,hdmi_stream_budget;
    wire [9:0] hdmi_jitter_peak;
    hdmi_scanout_admission hdmi_admission(
      .clock(ddr_clk),.reset_n(ddr_rstn),.frame_start_i(render_grant),
      .enabled_i(streaming_sync[1]&&!raw_reverse[render_source_bank]&&static_geometry),
      .render_active_i(render_active),.view_i(requested_view_i),.mode_i(display_mode_i),
      .source_rows_i(raw_committed[render_source_bank]),.source_complete_i(raw_complete[render_source_bank]),
      .source_failed_i(raw_failed[render_source_bank]),.output_rows_i(bank_rows_committed[render_destination_bank]),
      .status_o(hdmi_admission_status_o),.admit_o(hdmi_stream_admit),.live_fault_o(hdmi_stream_fault),.budget_fault_o(hdmi_stream_budget),.jitter_peak_o(hdmi_jitter_peak));
    reg [9:0] last_failure_reason;
    wire [9:0] current_failure_reason={
        render_error_reason[1]&&!(hdmi_admission_status_o[6]||hdmi_admission_status_o[5]||producer_fault||baseline_budget_fault),
        (baseline_fast?baseline_budget_fault:producer_fault),scan_failed,
        render_error_reason[5:2],hdmi_admission_status_o[6:5],render_error_reason[0]};
    assign hdmi_stability_o={1'b0,last_failure_reason,hdmi_jitter_peak};
    always @(posedge ddr_clk)begin
        if(!ddr_rstn)begin last_failure_reason<=0;hdmi_stability_valid_o<=0;end
        else begin
            hdmi_stability_valid_o<=render_done||scan_failed;
            if(render_done&&render_error)last_failure_reason<=current_failure_reason;
            else if(scan_failed)last_failure_reason<=10'b0010000000;
        end
    end
    wire selected_producer_fault=(baseline_fast ? baseline_budget_fault : producer_fault)||hdmi_stream_fault;
    assign live_admit=bank_mode[render_destination_bank]==0 ? raw_complete[render_source_bank]||hdmi_stream_admit :
        admission_ready||(baseline_fast&&baseline_admit_q&&render_active&&!render_grant&&!baseline_budget_fault&&!raw_failed[render_source_bank])||hdmi_stream_admit;
    always @(posedge ddr_clk)begin
        if(!ddr_rstn)begin bank_rows_committed[0]<=0;bank_rows_committed[1]<=0;display_command_busy<=0;end
        else begin
            if(render_grant)bank_rows_committed[render_destination_bank]<=0;
            else if(render_progress)bank_rows_committed[render_destination_bank]<=render_rows_committed;
            if(display_ddr_rreq)display_command_busy<=1;
            else if(display_ddr_rdone)display_command_busy<=0;
        end
    end
    always @(posedge ddr_clk)begin
      if(!ddr_rstn)raw_reverse<=0;
      else if(camera_accept)raw_reverse[camera_write_bank]<=source_reverse_i;
    end
    reg [31:0] capture_drops,render_errors,pose_fallbacks;
    // Decouple the mode/pose/grant decision from a 32-bit diagnostic counter.
    // This changes only the publication edge of the count, never a pixel or
    // a bank-allocation decision.
    reg pose_fallback_event;
    always @(posedge ddr_clk)begin
      if(!ddr_rstn)pose_fallback_event<=0;
      else pose_fallback_event<=render_grant&&dynamic_request&&!pose_render_ready;
    end
    reg [31:0] raw_pose_wait[0:2],raw_slot_wait[0:2],bank_pose_wait[0:1],bank_slot_wait[0:1];
    integer wait_index;
    always @(posedge ddr_clk)begin
      if(!ddr_rstn)begin for(wait_index=0;wait_index<3;wait_index=wait_index+1)begin raw_pose_wait[wait_index]<=0;raw_slot_wait[wait_index]<=0;end bank_pose_wait[0]<=0;bank_pose_wait[1]<=0;bank_slot_wait[0]<=0;bank_slot_wait[1]<=0;end
      else begin
       if(camera_accept)begin raw_pose_wait[camera_write_bank]<=0;raw_slot_wait[camera_write_bank]<=0;end
       if(pending_valid&&pending_bank<3&&!render_active)begin
        if(dynamic_request&&!pose_candidate_ready)raw_pose_wait[pending_bank]<=raw_pose_wait[pending_bank]+1'b1;
        else if(!render_grant)raw_slot_wait[pending_bank]<=raw_slot_wait[pending_bank]+1'b1;
       end
       if(render_grant)begin bank_pose_wait[render_destination_bank]<=raw_pose_wait[render_source_bank];bank_slot_wait[render_destination_bank]<=raw_slot_wait[render_source_bank];end
      end
    end
    always @(posedge ddr_clk)begin
      if(!ddr_rstn)begin capture_drops<=0;render_errors<=0;pose_fallbacks<=0;bank_counters[0]<=0;bank_counters[1]<=0;bank_cache_stats[0]<=0;bank_cache_stats[1]<=0;bank_frame_ids[0]<=0;bank_frame_ids[1]<=0;bank_frame_ticks[0]<=0;bank_frame_ticks[1]<=0;for(raw_index=0;raw_index<3;raw_index=raw_index+1)begin raw_frame_ids[raw_index]<=0;raw_frame_ticks[raw_index]<=0;end end
      else begin
        if(first_sync[2]^first_sync[1])begin raw_frame_ids[camera_write_bank]<=frame_id_i;raw_frame_ticks[camera_write_bank]<=frame_tick_i;end
        if(camera_drop)capture_drops<=capture_drops+1'b1;
        if(render_done&&render_error)render_errors<=render_errors+1'b1;
        if(render_grant)begin bank_counters[render_destination_bank]<=0;bank_frame_ids[render_destination_bank]<=raw_frame_ids[render_source_bank];bank_frame_ticks[render_destination_bank]<=raw_frame_ticks[render_source_bank];end
        if(pose_fallback_event)pose_fallbacks<=pose_fallbacks+1'b1;
        if(render_done&&!render_error)begin bank_counters[render_destination_bank]<=render_counters;bank_cache_stats[render_destination_bank]<=render_cache_stats;end
      end
    end
    // Refresh an early-visible frame once its producer finishes. The one-edge
    // delay lets final counters and frame metric registers settle atomically.
    reg diagnostics_completed;reg [1:0] diagnostics_completed_bank;
    always @(posedge ddr_clk)begin
        if(!ddr_rstn)begin diagnostics_completed<=0;diagnostics_completed_bank<=0;end
        else begin
            diagnostics_completed<=render_done&&!render_error&&display_valid&&display_bank==render_destination_bank;
            diagnostics_completed_bank<=render_destination_bank;
        end
    end
    assign diagnostics_valid_o=metrics_new_display||(diagnostics_completed&&display_valid&&display_bank==diagnostics_completed_bank);
    wire live_diagnostic=render_active&&display_bank==render_destination_bank;
    wire [543:0] diagnostic_counters=live_diagnostic?render_counters:bank_counters[display_bank];
    wire [159:0] diagnostic_cache=live_diagnostic?render_cache_stats:bank_cache_stats[display_bank];
    assign diagnostics_data_o={diagnostic_cache,diagnostic_counters[543:320],bank_slot_wait[display_bank],bank_pose_wait[display_bank],diagnostic_counters[319:0],pose_fallbacks,render_errors,metrics_ddr[9*32+:32],capture_drops,
      metrics_ddr[8*32+:32],metrics_ddr[7*32+:32],metrics_ddr[6*32+:32],metrics_ddr[5*32+:32],
      metrics_ddr[4*32+:32],metrics_ddr[3*32+:32],metrics_ddr[2*32+:32],metrics_ddr[1*32+:32],metrics_ddr[0*32+:32],metrics_ddr[10*32+:32],
      {metrics_ddr[11*32+:16],(live_diagnostic?8'h84:8'h04),(bank_view[display_bank]<5||bank_view[display_bank]==6),bank_stabilized[display_bank],bank_mode[display_bank],first_before_done,bank_view[display_bank]},bank_frame_ids[display_bank]};
    always @(posedge ddr_clk)begin
      if(!ddr_rstn)begin raw_complete<=0;raw_failed<=0;for(raw_index=0;raw_index<3;raw_index=raw_index+1)raw_committed[raw_index]<=0;end
      else begin
        if(camera_write_active&&camera_write_bank<3)begin
          raw_committed[camera_write_bank]<=capture_committed;
          if(capture_failed)raw_failed[camera_write_bank]<=1;
        end
        if(camera_frame_start&&camera_write_active&&!raw_complete[camera_write_bank])raw_failed[camera_write_bank]<=1;
        if(camera_frame_complete)begin raw_complete[camera_write_bank]<=1;raw_committed[camera_write_bank]<=720;end
        if(camera_accept)begin raw_complete[camera_write_bank]<=0;raw_failed[camera_write_bank]<=0;raw_committed[camera_write_bank]<=0;end
      end
    end

    // One coherent mailbox per newly eligible source frame. No image/bank
    // ownership changes here: the original admission and fallback stay intact.
    reg [31:0] sync_cycle, sync_raw_start[0:2], sync_source_start;
    reg sync_waiting,sync_done;
    reg [1:0] sync_source_bank,sync_mode;
    integer sync_index;
    wire sync_raw_required=sync_mode==0||sync_mode==2;
    wire sync_candidate=(sync_done||(render_done&&!render_error)||live_admit)&&
        (!sync_raw_required||raw_complete[sync_source_bank]||hdmi_stream_admit);
    always @(posedge ddr_clk)begin
      if(!ddr_rstn)begin
        sync_cycle<=0;sync_source_start<=0;sync_waiting<=0;sync_done<=0;
        sync_source_bank<=0;sync_mode<=0;sync_ready_toggle_o<=0;sync_ready_cycles_o<=0;
        for(sync_index=0;sync_index<3;sync_index=sync_index+1)sync_raw_start[sync_index]<=0;
      end else begin
        sync_cycle<=sync_cycle+1'b1;
        if(camera_accept)sync_raw_start[camera_write_bank]<=sync_cycle;
        if(render_grant)begin
          sync_waiting<=1;sync_done<=0;sync_source_start<=sync_raw_start[render_source_bank];
          sync_source_bank<=render_source_bank;sync_mode<=display_mode_i;
        end else begin
          if(render_done)begin
            if(render_error)sync_waiting<=0;else sync_done<=1;
          end
          if(sync_waiting&&sync_source_bank<3&&!raw_failed[sync_source_bank]&&sync_candidate)begin
            sync_ready_cycles_o<=((sync_cycle-sync_source_start)>32'h00ffffff) ? 24'hffffff : sync_cycle-sync_source_start;
            sync_ready_toggle_o<=~sync_ready_toggle_o;sync_waiting<=0;
          end
        end
      end
    end

    // Break the pose-ring match/timeout -> frame-allocation combinational path.
    // A changed candidate bank must wait for its own registered readiness.
    // Reused camera banks cannot become candidates until a new line commits;
    // camera_accept clears the old readiness before that can occur.
    always @(posedge ddr_clk)begin
      if(!ddr_rstn)begin pose_pending_ready_q<=0;pose_pending_bank_q<=0;pose_pending_view_q<=0;pose_pending_sequence_q<=0;end
      else begin
        pose_pending_bank_q<=pending_bank;pose_pending_view_q<=requested_view_i;pose_pending_sequence_q<=requested_seq_i;
        pose_pending_ready_q<=pending_valid&&pose_pending_ready&&!camera_accept;
      end
    end
    // Bank ownership changes at completed camera/renderer/HDMI frame edges.
    progressive_frame_bank_manager u_banks (
        .clock(ddr_clk), .reset_n(ddr_rstn),
        .camera_frame_start_i(camera_frame_start),.camera_committed_lines_i(capture_committed),
        // A good raw frame ends at its final DDR write acknowledgement.
        // At the next VSYNC, also release an incomplete frame without
        // publishing it, so the camera can allocate a fresh bank.
        .camera_frame_end_i(camera_frame_complete || camera_frame_start),
        .camera_frame_complete_i(camera_frame_complete),
        .render_request_i(calibration_loaded&&(!dynamic_request||pose_candidate_ready)),
        .prefer_fresh_i(streaming_sync[1]&&certified_phase_sync[1]&&phase_locked_sync[1]&&requested_view_i==7&&display_mode_i==3&&!dynamic_request),
        .pending_valid_o(pending_valid),.pending_bank_o(pending_bank),
        .render_done_i(render_done && !render_error),
        .render_failed_i(render_done && render_error),
        .hdmi_frame_start_i(hdmi_frame_start),
        .live_admit_i(live_admit),.prefer_live_i(hdmi_stream_admit),.scan_failed_i(scan_failed||(selected_live&&((baseline_fast ? baseline_budget_fault : producer_fault)&&bank_mode[render_destination_bank]!=0||hdmi_stream_fault))),
        .display_command_busy_i(display_command_busy||display_ddr_rreq),
        .camera_accept_o(camera_accept), .camera_drop_o(camera_drop),
        .camera_write_active_o(camera_write_active),
        .camera_write_bank_o(camera_write_bank),
        .render_grant_o(render_grant), .render_active_o(render_active),
        .render_source_bank_o(render_source_bank),
        .render_destination_bank_o(render_destination_bank),
        .display_valid_o(display_valid), .display_bank_o(display_bank),
        .display_live_o(display_live),.display_fault_o(display_fault),
        .display_raw_bank_o(display_raw_bank)
    );

    // The frame decision is made in DDR clock domain. Resynchronize the level
    // into the camera clock before admitting active-video pixels to wr_buf.
    reg capture_meta;

    always @(posedge vin_clk) begin
        capture_meta <= camera_write_active;
        capture_enabled <= capture_meta;
    end

    wr_buf #(
        .ADDR_WIDTH(CTRL_ADDR_WIDTH), .ADDR_OFFSET(32'd0),
        .H_NUM(H_NUM), .V_NUM(V_NUM), .DQ_WIDTH(MEM_DQ_WIDTH),
        .LEN_WIDTH(LEN_WIDTH), .PIX_WIDTH(PIX_WIDTH),
        .LINE_ADDR_WIDTH(FRAME_ADDR_BITS),
        .FRAME_CNT_WIDTH(CTRL_ADDR_WIDTH-FRAME_ADDR_BITS)
    ) u_raw_capture (
        .ddr_clk(ddr_clk), .ddr_rstn(ddr_rstn),
        .wr_clk(vin_clk), .wr_fsync(wr_fsync),
        .wr_en(wr_en && capture_enabled), .wr_data(wr_data),
        .rd_bac(camera_ddr_bac),.capture_abort_i(capture_abort_i),
        .ddr_wreq(camera_ddr_wreq), .ddr_waddr(camera_ddr_waddr),
        .ddr_wr_len(camera_ddr_wr_len), .ddr_wrdy(camera_ddr_wrdy),
        .ddr_wdone(camera_ddr_wdone), .ddr_wdata(camera_ddr_wdata),
        .ddr_wdata_req(camera_ddr_wdata_req),
        .write_bank(camera_write_bank),
        .frame_start(camera_frame_start),
        .frame_wirq(camera_frame_complete),.drained_o(capture_drained_o),.committed_lines_o(capture_committed),.capture_failed_o(capture_failed)
    );

    // Two corrected banks follow the three raw frame slots. The display
    // FIFO retains the previous bottom-to-top DDR line address order.
    rd_buf #(
        .ADDR_WIDTH(CTRL_ADDR_WIDTH), .ADDR_OFFSET(32'h0018_0000),
        .H_NUM(H_NUM), .V_NUM(V_NUM), .DQ_WIDTH(MEM_DQ_WIDTH),
        .LEN_WIDTH(LEN_WIDTH), .PIX_WIDTH(PIX_WIDTH),
        .LINE_ADDR_WIDTH(FRAME_ADDR_BITS),
        .FRAME_CNT_WIDTH(CTRL_ADDR_WIDTH-FRAME_ADDR_BITS),.SUPPORT_PROGRESSIVE(1)
    ) u_corrected_display (
        .ddr_clk(ddr_clk), .ddr_rstn(ddr_rstn),
        .vout_clk(vout_clk), .rd_fsync(rd_fsync), .rd_en(rd_en),
        .vout_de(display_de), .vout_data(display_pixel),
        .vout_content_de(display_content_de),.displayed_hdmi_o(displayed_hdmi_o),
        .init_done(display_valid), .read_bank(display_bank),
        .display_live_i(display_live),.display_failed_i(display_fault),
        .corrected_committed_i(bank_rows_committed[display_bank]),.scan_failed_o(scan_failed),
        .raw_committed_i(raw_committed[display_raw_bank]),.raw_complete_i(raw_complete[display_raw_bank]),.raw_failed_i(raw_failed[display_raw_bank]),
        // RAW can be selected immediately. Corrected layouts are committed
        // with their completed frame, so QUAD cannot display a native pane.
        .source_frame_i(bank_frame_ids[display_bank]),.source_tick_i(bank_frame_ticks[display_bank]),
        .source_frame_o(displayed_source_frame_o),.source_tick_o(displayed_source_tick_o),
        .raw_read_bank(display_raw_bank), .display_mode_i(display_mode_i==0 ? 2'd0 : bank_mode[display_bank]),
        .display_reverse_i(raw_reverse[display_raw_bank]),
        .display_stabilized_i(bank_stabilized[display_bank]),.display_stabilized_o(display_stabilized_o),
        .display_view_i(bank_view[display_bank]),.display_seq_i(bank_seq[display_bank]),
        .display_view_o(display_view_o),.display_seq_o(display_seq_o),
        .display_mode_o(display_mode_o),
        .frame_rirq(hdmi_frame_start),
        .ddr_rreq(display_ddr_rreq),
        .ddr_raddr(display_ddr_raddr), .ddr_rd_len(display_ddr_rd_len),
        .ddr_rrdy(display_ddr_rrdy), .ddr_rdone(display_ddr_rdone),
        .ddr_rdata(display_ddr_rdata),
        .ddr_rdata_en(display_ddr_rdata_en)
    );

    reg display_valid_meta;
    reg display_valid_sync;
    always @(posedge vout_clk) begin
        display_valid_meta <= display_valid;
        display_valid_sync <= display_valid_meta;
    end
    assign vout_de = display_de;
    assign vout_content_de = display_content_de && display_valid_sync;
    assign vout_data = display_valid_sync ? display_pixel : {PIX_WIDTH{1'b0}};

    video_frame_metrics u_video_frame_metrics (
        .ddr_clk(ddr_clk), .reset_n(ddr_rstn),
        .vin_clk(vin_clk), .camera_vsync(wr_fsync),
        .camera_pixel_valid(wr_en && capture_enabled),
        .camera_accept(camera_accept), .camera_bank(camera_write_bank),
        .camera_frame_start(camera_frame_start),
        .camera_frame_complete(camera_frame_complete),
        .render_grant(render_grant),
        .render_source_bank(render_source_bank),
        .render_destination_bank(render_destination_bank),
        .render_done(render_done && !render_error),
        .render_failed(render_done && render_error),
        .display_valid(display_valid), .display_bank(display_bank),
        .display_live_i(display_live),.first_before_done_o(first_before_done),
        .vout_clk(vout_clk), .hdmi_vsync(MEASURE_OUTPUT_FEEDBACK?measure_vsync_i:rd_fsync),
        .hdmi_pixel_valid(MEASURE_OUTPUT_FEEDBACK?measure_content_i:(display_content_de && display_valid_sync)),
        .hdmi_de(MEASURE_OUTPUT_FEEDBACK?measure_de_i:display_de),
        .processing_state_i({display_stabilized_o,MEASURE_OUTPUT_FEEDBACK?measure_enhanced_i:1'b0}),
        .display_mode_i(display_mode_o),.display_view_i(display_view_o),
        .pane_first_tenths_o(pane_first_tenths_o),.pane_end_tenths_o(pane_end_tenths_o),
        .pane_first_valid_o(pane_first_valid_o),.pane_end_valid_o(pane_end_valid_o),.pane_layout_o(pane_layout_o),
        .latency_tenth_ms(latency_tenth_ms_o),
        .latency_valid(latency_valid_o),
        .capture_tenth_ms(capture_tenth_ms_o),
        .queue_tenth_ms(queue_tenth_ms_o),
        .render_tenth_ms(render_tenth_ms_o),
        .display_tenth_ms(display_tenth_ms_o),
        .corrected_fps(corrected_fps_o),
        .camera_fps_tenths(camera_fps_tenths_o),
        .camera_rate_valid(camera_rate_valid_o),
        .raw_fps(raw_fps_o),
        .render_fps(render_fps_o),
        .output_refresh_tenths(output_refresh_tenths_o),
        .output_refresh_valid(output_refresh_valid_o),.diagnostics_ddr_o(metrics_ddr),.new_display_pulse_o(metrics_new_display)
    );

    always @(posedge ddr_clk) begin
        if (!ddr_rstn)
            init_done <= 1'b0;
        else if (display_valid)
            init_done <= 1'b1;
    end

    wr_rd_ctrl_top #(
        .CTRL_ADDR_WIDTH(CTRL_ADDR_WIDTH), .MEM_DQ_WIDTH(MEM_DQ_WIDTH)
    ) u_legacy_transport (
        .clk(ddr_clk), .rstn(ddr_rstn),
        .wr_cmd_en(camera_ddr_wreq), .wr_cmd_addr(canonical_camera_waddr),
        .wr_cmd_len(camera_ddr_wr_len), .wr_cmd_ready(camera_ddr_wrdy),
        .wr_cmd_done(camera_ddr_wdone), .wr_bac(camera_ddr_bac),
        .wr_ctrl_data(camera_ddr_wdata), .wr_data_re(camera_ddr_wdata_req),
        .rd_cmd_en(display_ddr_rreq), .rd_cmd_addr(display_ddr_raddr),
        .rd_cmd_len(display_ddr_rd_len), .rd_cmd_ready(display_ddr_rrdy),
        .rd_cmd_done(display_ddr_rdone), .read_ready(1'b1),
        .read_rdata(display_ddr_rdata), .read_en(display_ddr_rdata_en),
        .axi_awaddr(m0_awaddr), .axi_awid(m0_awid),
        .axi_awlen(m0_awlen), .axi_awsize(), .axi_awburst(),
        .axi_awready(m0_awready), .axi_awvalid(m0_awvalid),
        .axi_wdata(m0_wdata), .axi_wstrb(m0_wstrb),
        .axi_wlast(m0_wlast), .axi_wvalid(), .axi_wready(m0_wready),
        .axi_bid(4'd0), .axi_bresp(2'd0), .axi_bvalid(1'b0),
        .axi_bready(),
        .axi_araddr(m0_araddr), .axi_arid(m0_arid),
        .axi_arlen(m0_arlen), .axi_arsize(), .axi_arburst(),
        .axi_arvalid(m0_arvalid), .axi_arready(m0_arready),
        .axi_rready(), .axi_rdata(m0_rdata),
        .axi_rvalid(m0_rvalid), .axi_rlast(m0_rlast),
        .axi_rid(m0_rid), .axi_rresp(2'd0)
    );

    wire capture_tap_valid,capture_tap_error;
    wire [31:0] capture_tap_frame;
    wire [1:0] capture_tap_bank;
    wire [10:0] capture_tap_x,capture_tap_y;
    wire [255:0] capture_tap_pixels;

    // The RAW slot identity is sampled at each accepted camera AW, not from
    // the global newest camera frame while an older transaction drains.
    capture_beat_tap capture_tap (
        .clock(ddr_clk),.reset_n(ddr_rstn),.awvalid_i(m0_awvalid),.awready_i(m0_awready),
        .awaddr_i(m0_awaddr),.awlen_i(m0_awlen),.frame_id_i(raw_frame_ids[m0_awaddr[20:19]]),
        .wready_i(m0_wready),.wlast_i(m0_wlast),.wdata_i(m0_wdata),
        .valid_o(capture_tap_valid),.frame_id_o(capture_tap_frame),.source_bank_o(capture_tap_bank),
        .source_x_o(capture_tap_x),.source_y_o(capture_tap_y),.pixels_o(capture_tap_pixels),.error_o(capture_tap_error)
    );
    tile_renderer #(.USE_SHARED_SOURCE(1),.SOURCE_CAPTURE_REVERSE(SOURCE_CAPTURE_REVERSE)) u_renderer (.source_reverse_i(raw_reverse[render_source_bank]),
        .clock(ddr_clk), .reset_n(ddr_rstn),
        .view_i(requested_view_i),.pose_enable_i(dynamic_request&&pose_render_ready),.pose_matrix_i(frame_pose),
        .pose_views_i(frame_views),.pose_allviews_i(frame_allviews),
        .start_i(render_grant), .source_bank_i(render_source_bank),
        .abort_i(selected_live&&((baseline_fast ? baseline_budget_fault : producer_fault)&&bank_mode[render_destination_bank]!=0||hdmi_stream_fault)),
        .frame_id_i(raw_frame_ids[render_source_bank]),.tap_valid_i(capture_tap_valid),
        .tap_frame_i(capture_tap_frame),.tap_bank_i(capture_tap_bank),
        .tap_x_i(capture_tap_x),.tap_y_i(capture_tap_y),.tap_pixels_i(capture_tap_pixels),.cache_stats_o(source_cache_stats),
        .source_complete_i(raw_complete[render_source_bank]),.source_failed_i(raw_failed[render_source_bank]),
        .source_committed_i(raw_committed[render_source_bank]),.counters_o(render_counters),.dependencies_ready_o(render_dependencies_ready),
        .rows_committed_o(render_rows_committed),.progress_valid_o(render_progress),
        .destination_bank_i(render_destination_bank),
        .busy_o(render_busy), .done_o(render_done), .error_o(render_error),.error_reason_o(render_error_reason),
        .cal_write_en_i(cal_write_en_i),
        .cal_table_select_i(cal_table_select_i),
        .cal_write_addr_i(cal_write_addr_i),
        .cal_write_data_i(cal_write_data_i),
        .cal_commit_i(cal_commit_i),
        .calibration_loaded_o(calibration_loaded),
        .axi_araddr(m1_araddr), .axi_arlen(m1_arlen),
        .axi_arid(m1_arid), .axi_arvalid(m1_arvalid),
        .axi_arready(m1_arready), .axi_rdata(m1_rdata),
        .axi_rvalid(m1_rvalid), .axi_rlast(m1_rlast),
        .axi_awaddr(m1_awaddr), .axi_awlen(m1_awlen),
        .axi_awid(m1_awid), .axi_awvalid(m1_awvalid),
        .axi_awready(m1_awready), .axi_wdata(m1_wdata),
        .axi_wstrb(m1_wstrb), .axi_wready(m1_wready),
        .axi_wlast(m1_wlast)
    );

    ddr_burst_arbiter u_ddr_arbiter (
        .clock(ddr_clk), .reset_n(ddr_rstn),
        .m0_awaddr(m0_awaddr), .m0_awlen(m0_awlen), .m0_awid(m0_awid),
        .m0_awvalid(m0_awvalid), .m0_awready(m0_awready),
        .m0_wdata(m0_wdata), .m0_wstrb(m0_wstrb),
        .m0_wready(m0_wready), .m0_wlast(m0_wlast),
        .m1_awaddr(m1_awaddr), .m1_awlen(m1_awlen), .m1_awid(m1_awid),
        .m1_awvalid(m1_awvalid), .m1_awready(m1_awready),
        .m1_wdata(m1_wdata), .m1_wstrb(m1_wstrb),
        .m1_wready(m1_wready), .m1_wlast(m1_wlast),
        .m0_araddr(m0_araddr), .m0_arlen(m0_arlen), .m0_arid(m0_arid),
        .m0_arvalid(m0_arvalid), .m0_arready(m0_arready),
        .m0_rdata(m0_rdata), .m0_rvalid(m0_rvalid),
        .m0_rlast(m0_rlast), .m0_rid(m0_rid),
        .m1_araddr(m1_araddr), .m1_arlen(m1_arlen), .m1_arid(m1_arid),
        .m1_arvalid(m1_arvalid), .m1_arready(m1_arready),
        .m1_rdata(m1_rdata), .m1_rvalid(m1_rvalid),
        .m1_rlast(m1_rlast), .m1_rid(m1_rid),
        .ddr_awaddr(axi_awaddr), .ddr_awlen(axi_awlen),
        .ddr_awid(axi_awid), .ddr_awvalid(axi_awvalid),
        .ddr_awready(axi_awready), .ddr_wdata(axi_wdata),
        .ddr_wstrb(axi_wstrb), .ddr_wready(axi_wready),
        .ddr_wlast(axi_wlast),
        .ddr_araddr(axi_araddr), .ddr_arlen(axi_arlen),
        .ddr_arid(axi_arid), .ddr_arvalid(axi_arvalid),
        .ddr_arready(axi_arready), .ddr_rdata(axi_rdata),
        .ddr_rvalid(axi_rvalid), .ddr_rlast(axi_rlast),
        .ddr_rid(axi_rid)
    );

    assign axi_awsize = 3'd5;
    assign axi_awburst = 2'b01;
    assign axi_wvalid = 1'b1;
    assign axi_arsize = 3'd5;
    assign axi_arburst = 2'b01;
    assign axi_rready = 1'b1;
    assign calibration_loaded_o = calibration_loaded;
endmodule
