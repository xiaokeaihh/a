`timescale 1ns/1ps

// Matched raw/corrected DDR frame pair -> HDMI. Compare mode displays two
// complete half-size pictures, centered vertically with the native aspect ratio.
module rd_buf #(
    parameter ADDR_WIDTH = 28, ADDR_OFFSET = 0,
    parameter H_NUM = 1280, V_NUM = 720,
    parameter DQ_WIDTH = 32, LEN_WIDTH = 32, PIX_WIDTH = 16,
    parameter LINE_ADDR_WIDTH = 22, FRAME_CNT_WIDTH = 6,
    parameter COR_VALID_SPANS_FILE = "source/design_fisheye_5frame_720p60_pipeline/data/rect_spans.mem",
    parameter integer SUPPORT_PROGRESSIVE=0
) (
    input ddr_clk, input ddr_rstn,
    input vout_clk, input rd_fsync, input rd_en,
    output vout_de, output [PIX_WIDTH-1:0] vout_data,
    output vout_content_de,output wire displayed_hdmi_o,
    input wire display_stabilized_i,output reg display_stabilized_o,
    input wire [31:0] source_frame_i,source_tick_i,
    output reg [31:0] source_frame_o,source_tick_o,
    input wire [2:0] display_view_i,output reg [2:0] display_view_o,
    input wire [7:0] display_seq_i,output reg [7:0] display_seq_o,
    input init_done, input [1:0] read_bank,
    input wire display_live_i,display_failed_i,
    input wire [10:0] corrected_committed_i,
    input wire [10:0] raw_committed_i,input wire raw_complete_i,raw_failed_i,
    output wire scan_failed_o,
    input [1:0] raw_read_bank, input [1:0] display_mode_i,
    input wire display_reverse_i,
    output frame_rirq, output [1:0] display_mode_o,
    output reg ddr_rreq,
    output [ADDR_WIDTH-1:0] ddr_raddr,
    output [LEN_WIDTH-1:0] ddr_rd_len,
    input ddr_rrdy, input ddr_rdone,
    input [8*DQ_WIDTH-1:0] ddr_rdata, input ddr_rdata_en
);
    localparam integer DDR_WIDTH = 8*DQ_WIDTH;
    localparam integer LINE_BEATS = H_NUM*PIX_WIDTH/DDR_WIDTH;
    localparam integer ADDR_STEP = LINE_BEATS*DDR_WIDTH/DQ_WIDTH;
    localparam integer COMPARE_LINES = V_NUM/2;
    localparam integer COMPARE_TOP = (V_NUM-COMPARE_LINES)/2;
    localparam integer FIFO_BEATS = 512;
    localparam integer READ_HEADROOM = 16;

    reg [1:0] pix_reset_sync;
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) pix_reset_sync <= 2'b00;
        else           pix_reset_sync <= {pix_reset_sync[0], 1'b1};
    end
    reg fsync_d;
    reg frame_toggle;
    wire output_frame_start = rd_fsync && !fsync_d;
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            fsync_d <= 1'b0;
            frame_toggle <= 1'b0;
        end else begin
            fsync_d <= rd_fsync;
            if (output_frame_start && pix_reset_sync[1])
                frame_toggle <= ~frame_toggle;
        end
    end
    reg [2:0] frame_sync;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) frame_sync <= 3'b000;
        else           frame_sync <= {frame_sync[1:0], frame_toggle};
    end
    wire ddr_frame_edge = frame_sync[2] ^ frame_sync[1];
    assign frame_rirq = ddr_frame_edge;

    wire fifo_full, fifo_empty, fifo_valid;
    wire [9:0] fifo_wr_level;
    wire [12:0] fifo_rd_level;
    wire [31:0] fifo_word;
    reg pixel_phase;
    reg [1:0] frame_mode;
    reg frame_reverse;
    assign displayed_hdmi_o=!frame_reverse;
    reg [1:0] compare_phase;
    reg [2:0] scaler_drain;
    reg metadata_pending;
    reg frame_live,frame_failed;
    reg pixel_fault,fault_toggle;
    reg [1:0] failed_pixel_sync;
    reg [2:0] fault_ddr_sync;
    always @(posedge vout_clk or negedge ddr_rstn)begin
        if(!ddr_rstn)failed_pixel_sync<=0;
        else failed_pixel_sync<={failed_pixel_sync[0],frame_failed};
    end
    always @(posedge ddr_clk or negedge ddr_rstn)begin
        if(!ddr_rstn)fault_ddr_sync<=0;
        else fault_ddr_sync<={fault_ddr_sync[1:0],fault_toggle};
    end
    assign scan_failed_o=SUPPORT_PROGRESSIVE&&(fault_ddr_sync[2]^fault_ddr_sync[1]);
    reg [1:0] stable_sync;
    always @(posedge vout_clk)if(!ddr_rstn)stable_sync<=0;else stable_sync<={stable_sync[0],display_stabilized_o};
    reg [2:0] view_meta,view_sync;
    always @(posedge vout_clk)begin view_meta<=display_view_o;view_sync<=view_meta;end
    reg [1:0] mode_meta, mode_sync;
    reg [11:0] output_x, output_y;
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            mode_meta <= 2'd0;
            mode_sync <= 2'd0;
            output_x <= 12'd0;
            output_y <= 12'd0;
        end else begin
            // frame_mode changes during VSYNC and settles before active video.
            mode_meta <= frame_mode;
            mode_sync <= mode_meta;
            if (output_frame_start) begin
                output_x <= 12'd0;
                output_y <= 12'd0;
            end else if (rd_en) begin
                if (output_x == H_NUM-1) begin
                    output_x <= 12'd0;
                    output_y <= output_y + 1'b1;
                end else output_x <= output_x + 1'b1;
            end
        end
    end
    wire consume_pixel = mode_sync != 2'd2 ||
                         (output_y >= COMPARE_TOP &&
                          output_y < COMPARE_TOP+COMPARE_LINES);
    // Native COR panes are stored compactly; black layout pixels are generated here.
    wire native_single_pix=(view_sync<5)||(view_sync==6);
    wire native_single_ddr=(display_view_o<5)||(display_view_o==6);
    wire visible_pixel=consume_pixel;
    wire fifo_pop = rd_en && consume_pixel && !pixel_phase && fifo_valid && !pixel_fault && !failed_pixel_sync[1];
    wire [DDR_WIDTH-1:0] scaled_data;
    wire scaled_valid;
    reg request_active;
    // A previous AXI command may finish after VSYNC. Drain it in transport,
    // but do not feed its old pixels into this frame's freshly reset FIFO.
    wire accepted_read_data = ddr_rdata_en && request_active && !ddr_frame_edge;
    wire bypass_compare_scaler=frame_mode==2'd2&&native_single_ddr&&compare_phase==2;
    // Scaler output can trail the source-line completion. Select by its valid
    // token, so moving from RAW phase 1 to native COR phase 2 loses no tail beat.
    wire [DDR_WIDTH-1:0] line_input = frame_mode == 2'd2&&scaled_valid ? scaled_data : ddr_rdata;
    wire line_input_valid = !ddr_frame_edge && !frame_failed && (frame_mode == 2'd2 ? scaled_valid||(bypass_compare_scaler&&accepted_read_data) : accepted_read_data);
    wire [DDR_WIDTH-1:0] fifo_input, unmirrored_data;
    wire fifo_input_valid, unmirrored_valid, mirror_busy;
    // The sensor's inherited horizontal orientation plus bottom-to-top DDR
    // display produced a reflection. Reverse each picture's output columns,
    // after geometric sampling: the calibrated sensor coordinates stay intact.
    // SPL retains RAW on the left; QUAD follows the full image orientation.
    // OSD/metadata are added later and retain their original positions.
    // HDMI frames already have ordinary top-left coordinates. Only camera
    // frames need the inherited display rotation; keep this tag with the bank.
    assign fifo_input=frame_reverse ? unmirrored_data : line_input;
    assign fifo_input_valid=frame_reverse ? unmirrored_valid : line_input_valid;
    rgb565_unmirror_line #(.DATA_WIDTH(DDR_WIDTH),.LINE_BEATS(LINE_BEATS))
    u_unmirror (
        .clock(ddr_clk),.reset_n(ddr_rstn),.frame_reset(ddr_frame_edge),
        .split_i(frame_mode==2'd2),
        .data_i(line_input),.valid_i(line_input_valid&&frame_reverse),
        .data_o(unmirrored_data),.valid_o(unmirrored_valid),.busy_o(mirror_busy)
    );
    video_async_fifo #(
        .WR_DATA_WIDTH(DDR_WIDTH), .RD_DATA_WIDTH(32),
        .WR_DEPTH_WIDTH(9), .RD_DEPTH_WIDTH(12),
        .ALMOST_FULL(FIFO_BEATS-LINE_BEATS-READ_HEADROOM),
        .ALMOST_EMPTY(64)
    ) u_display_fifo (
        .wr_clk(ddr_clk), .wr_rst(!ddr_rstn || ddr_frame_edge),
        .wr_data(fifo_input), .wr_en(fifo_input_valid),
        .wr_full(fifo_full), .almost_full(), .wr_level(fifo_wr_level),
        .rd_clk(vout_clk), .rd_rst(!pix_reset_sync[1] || output_frame_start),
        .rd_data(fifo_word), .rd_en(fifo_pop),
        .rd_empty(fifo_empty), .rd_valid(fifo_valid),
        .almost_empty(), .rd_level(fifo_rd_level)
    );

    // Reserve a whole output line before its first DDR request. Compare mode
    // uses four source-line requests to produce the same 1280 output pixels. The
    // existing transport always accepts AXI read data, so this reservation
    // is what keeps the FIFO from overflowing without changing DDR IP.
    reg [11:0] completed_lines;
    reg [LINE_ADDR_WIDTH-1:0] address_count;
    reg frame_active;

    wire [11:0] output_lines = frame_mode == 2'd2 ? COMPARE_LINES : V_NUM;
    wire request_corrected=frame_mode==1||frame_mode==3||(frame_mode==2&&compare_phase[1]);
    wire [11:0] required_corrected_rows=frame_mode==2 ?
        (native_single_ddr ? completed_lines+12'd1 : (completed_lines<<1)+12'd1+compare_phase[0]) : completed_lines+12'd1;
    wire [11:0] required_raw_rows=frame_mode==2 ? (completed_lines<<1)+12'd1+compare_phase[0] : completed_lines+12'd1;
    wire raw_rows_ready=(raw_complete_i===1'b1)||raw_committed_i>=required_raw_rows;
    wire request_data_ready=!frame_live||(request_corrected ? corrected_committed_i>=required_corrected_rows : raw_rows_ready);
    assign display_mode_o = frame_mode;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            completed_lines <= 12'd0;
            address_count <= (V_NUM-1)*ADDR_STEP;
            request_active <= 1'b0;
            frame_active <= 1'b0;
            compare_phase <= 2'd0;
            frame_mode <= 2'd0;
            frame_reverse <= 1'b1;
            scaler_drain<=0;
            metadata_pending<=0;display_view_o<=6;display_seq_o<=0;display_stabilized_o<=0;
            source_frame_o<=0;source_tick_o<=0;
            frame_live<=0;frame_failed<=0;
            ddr_rreq <= 1'b0;
        end else begin
            ddr_rreq <= 1'b0;
            if(scaler_drain!=0)scaler_drain<=scaler_drain-1'b1;
            if(ddr_rdone&&request_active&&frame_mode==2&&compare_phase[0])scaler_drain<=4;
            metadata_pending<=ddr_frame_edge;
            if(!ddr_frame_edge&&SUPPORT_PROGRESSIVE&&((display_failed_i===1'b1)||(frame_live&&(raw_failed_i===1'b1))))frame_failed<=1;
            // Bank manager publishes the new bank on ddr_frame_edge. Sample
            // all of its metadata one edge later; mixing an old layout mode
            // with the new view would choose the wrong DDR read sequence.
            if(metadata_pending)begin
                display_view_o<=display_view_i;display_seq_o<=display_seq_i;display_stabilized_o<=(display_stabilized_i===1'b1);
                source_frame_o<=source_frame_i;source_tick_o<=source_tick_i;
                frame_mode<=display_mode_i;
                // Omitted port in older standalone fixtures retains camera
                // behavior. In the board design this is a per-raw-bank tag.
                frame_reverse<=display_reverse_i!==1'b0;
                address_count<=display_reverse_i!==1'b0 ? (V_NUM-1)*ADDR_STEP : 0;
                frame_live<=SUPPORT_PROGRESSIVE&&(display_live_i===1'b1);
                // First publication must start this scan, not wait for a
                // second VSYNC merely because INIT_DONE was previously low.
                frame_active<=init_done;
            end
            if (ddr_frame_edge) begin
                frame_failed<=0;
                scaler_drain<=0;
                completed_lines <= 12'd0;
                address_count <= (V_NUM-1)*ADDR_STEP;
                request_active <= 1'b0;
                frame_active <= init_done;
                compare_phase <= 2'd0;
            end else if (ddr_rdone && request_active) begin
                request_active <= 1'b0;
                if (frame_mode == 2'd2 && compare_phase != (native_single_ddr?2'd2:2'd3)) begin
                    compare_phase <= compare_phase + 1'b1;
                end else begin
                    compare_phase <= 2'd0;
                    completed_lines <= completed_lines + 1'b1;
                    if (frame_mode == 2'd2) begin
                        if (!frame_reverse)
                            address_count <= address_count + 2*ADDR_STEP;
                        else if (address_count >= 2*ADDR_STEP)
                            address_count <= address_count - 2*ADDR_STEP;
                    end else if (!frame_reverse)
                        address_count <= address_count + ADDR_STEP;
                    else if (address_count >= ADDR_STEP)
                        address_count <= address_count - ADDR_STEP;
                    if (completed_lines == output_lines-1)
                        frame_active <= 1'b0;
                end
            end else if (frame_active && !frame_failed && request_data_ready && !metadata_pending && !mirror_busy && scaler_drain==0 && !request_active && ddr_rrdy &&
                         completed_lines < output_lines &&
                         ((frame_mode == 2'd2 && compare_phase != 2'd0) ||
                          fifo_wr_level <= FIFO_BEATS-LINE_BEATS-READ_HEADROOM)) begin
                request_active <= 1'b1;
                ddr_rreq <= 1'b1;
            end
        end
    end
    wire read_corrected = (frame_mode == 2'd1) || (frame_mode == 2'd3) ||
                          (frame_mode == 2'd2 && compare_phase[1]);
    wire [LINE_ADDR_WIDTH-1:0] phase_offset=(frame_mode==2'd2&&compare_phase[0]) ? ADDR_STEP : 0;
    wire [LINE_ADDR_WIDTH-1:0] source_address=frame_reverse ? address_count-phase_offset : address_count+phase_offset;
    wire [LINE_ADDR_WIDTH-1:0] native_source_address=(frame_reverse ? 19'd359-completed_lines : completed_lines)*19'd320;
    assign ddr_raddr = read_corrected
                     ? {read_bank, bypass_compare_scaler?native_source_address:source_address} + ADDR_OFFSET
                     : {raw_read_bank, source_address};
    assign ddr_rd_len = bypass_compare_scaler?LINE_BEATS/2:LINE_BEATS;

    // Read both complete source rows. RGB565 channel sums implement a
    // rounded 2x2 box filter, producing one 640-pixel half-line per frame.
    rgb565_halfscale_2x2 #(.DATA_WIDTH(DDR_WIDTH), .LINE_BEATS(LINE_BEATS))
    u_compare_scaler (
        .clock(ddr_clk), .reset_n(ddr_rstn), .frame_reset(ddr_frame_edge),
        .line_start(ddr_rreq), .second_row(compare_phase[0]),
        .data_i(ddr_rdata), .valid_i(accepted_read_data && frame_mode == 2'd2&&!bypass_compare_scaler),
        .data_o(scaled_data), .valid_o(scaled_valid)
    );

    // The FIFO supplies each packed 32-bit word before the read edge.
    // Keep two pixel-clock pipeline stages to match the previous HDMI DE.
    reg [31:0] saved_word;
    reg saved_valid;
    reg [PIX_WIDTH-1:0] pixel_1d, pixel_2d;
    reg de_1d, de_2d;
    reg content_1d, content_2d;
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            pixel_phase <= 1'b0;
            saved_word <= 32'd0;
            saved_valid <= 1'b0;
            pixel_1d <= {PIX_WIDTH{1'b0}};
            pixel_2d <= {PIX_WIDTH{1'b0}};
            content_1d <= 1'b0;
            content_2d <= 1'b0;
            de_1d <= 1'b0;
            de_2d <= 1'b0;
            pixel_fault<=0;fault_toggle<=0;
        end else begin
            content_1d <= rd_en && visible_pixel &&
                          (pixel_phase ? saved_valid : fifo_valid) && !pixel_fault && !failed_pixel_sync[1];
            content_2d <= content_1d;
            de_1d <= rd_en;
            de_2d <= de_1d;
            pixel_2d <= pixel_1d;
            if(output_frame_start)pixel_fault<=0;
            else if(SUPPORT_PROGRESSIVE&&rd_en&&consume_pixel&&!pixel_fault&&
                    (failed_pixel_sync[1]||!(pixel_phase ? saved_valid : fifo_valid)))begin
                pixel_fault<=1;fault_toggle<=~fault_toggle;
            end
            if (!rd_en || output_frame_start || !consume_pixel || pixel_fault || failed_pixel_sync[1]) begin
                pixel_phase <= 1'b0;
                saved_valid <= 1'b0;
                pixel_1d <= {PIX_WIDTH{1'b0}};
            end else if (!pixel_phase) begin
                pixel_phase <= 1'b1;
                saved_word <= fifo_word;
                saved_valid <= fifo_valid;
                pixel_1d <= fifo_valid ? fifo_word[15:0] : 16'd0;
            end else begin
                pixel_phase <= 1'b0;
                pixel_1d <= saved_valid ? saved_word[31:16] : 16'd0;
            end
        end
    end
    assign vout_content_de = content_2d;
    assign vout_de = de_2d;
    assign vout_data = pixel_2d;
    wire unused_status = fifo_empty | fifo_full | fifo_rd_level[0];
endmodule

// One line, not a frame: reverse DDR beat order and the RGB565 lanes in each
// beat. A complete SPL line contains both panes. Only one output line is in
// flight; the requester waits during the bounded drain (80 clocks at 720p).
module rgb565_unmirror_line #(
    parameter integer DATA_WIDTH=256,
    parameter integer LINE_BEATS=80
)(
    input wire clock,reset_n,frame_reset,split_i,
    input wire [DATA_WIDTH-1:0] data_i,input wire valid_i,
    output wire [DATA_WIDTH-1:0] data_o,output reg valid_o,
    output reg busy_o
);
    localparam integer INDEX_WIDTH=$clog2(LINE_BEATS);
    localparam integer PIXELS=DATA_WIDTH/16;
    reg [DATA_WIDTH-1:0] line_memory[0:LINE_BEATS-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [INDEX_WIDTH-1:0] write_index,read_index;
    reg split_line;
    reg [DATA_WIDTH-1:0] read_word;
    wire [INDEX_WIDTH-1:0] source_index=split_line
        ? (read_index<LINE_BEATS/2 ? LINE_BEATS/2-1-read_index : LINE_BEATS+LINE_BEATS/2-1-read_index)
        : LINE_BEATS-1-read_index;
    // RAM data/read register intentionally have no reset for block-RAM inference.
    always @(posedge clock) begin
        if(reset_n&&!frame_reset&&valid_i&&!busy_o)line_memory[write_index]<=data_i;
        if(reset_n&&!frame_reset&&busy_o)read_word<=line_memory[source_index];
    end
    genvar lane;
    generate for(lane=0;lane<PIXELS;lane=lane+1)begin: reverse_lanes
        assign data_o[lane*16+:16]=read_word[(PIXELS-1-lane)*16+:16];
    end endgenerate
    always @(posedge clock or negedge reset_n)begin
        if(!reset_n)begin write_index<=0;read_index<=0;split_line<=0;busy_o<=0;valid_o<=0;end
        else if(frame_reset)begin write_index<=0;read_index<=0;busy_o<=0;valid_o<=0;end
        else begin
            valid_o<=busy_o;
            if(valid_i&&!busy_o)begin
                if(write_index==LINE_BEATS-1)begin
                    write_index<=0;read_index<=0;split_line<=split_i;busy_o<=1;
                end else write_index<=write_index+1'b1;
            end
            if(busy_o)begin
                if(read_index==LINE_BEATS-1)begin read_index<=0;busy_o<=0;end
                else read_index<=read_index+1'b1;
            end
        end
    end
endmodule

// One source line of horizontal RGB channel sums is kept in synchronous RAM.
// Two consecutive half-width output beats are repacked into one DDR-width beat.
module rgb565_halfscale_2x2 #(
    parameter integer DATA_WIDTH = 256,
    parameter integer LINE_BEATS = 80
) (
    input wire clock, input wire reset_n, input wire frame_reset,
    input wire line_start, input wire second_row,
    input wire [DATA_WIDTH-1:0] data_i, input wire valid_i,
    output reg [DATA_WIDTH-1:0] data_o, output reg valid_o
);
    localparam integer PAIRS = DATA_WIDTH/32;
    localparam integer SUM_WIDTH = PAIRS*19;
    localparam integer HALF_WIDTH = DATA_WIDTH/2;
    localparam integer INDEX_WIDTH = $clog2(LINE_BEATS);
    wire [SUM_WIDTH-1:0] horizontal_sum;
    reg [SUM_WIDTH-1:0] row_sums [0:LINE_BEATS-1];
    reg [SUM_WIDTH-1:0] previous_sum, current_sum;
    reg [INDEX_WIDTH-1:0] beat_index;
    reg pending_valid, pending_odd;
    reg [HALF_WIDTH-1:0] low_half;
    wire [HALF_WIDTH-1:0] reduced_pixels;
    genvar pair_index;
    generate for (pair_index=0; pair_index<PAIRS; pair_index=pair_index+1) begin: pairs
        wire [5:0] hr = {1'b0,data_i[pair_index*32+11 +: 5]} +
                       {1'b0,data_i[pair_index*32+27 +: 5]};
        wire [6:0] hg = {1'b0,data_i[pair_index*32+5 +: 6]} +
                       {1'b0,data_i[pair_index*32+21 +: 6]};
        wire [5:0] hb = {1'b0,data_i[pair_index*32 +: 5]} +
                       {1'b0,data_i[pair_index*32+16 +: 5]};
        assign horizontal_sum[pair_index*19 +: 19] = {hr,hg,hb};
        wire [6:0] vr = {1'b0,previous_sum[pair_index*19+13 +: 6]} +
                       {1'b0,current_sum[pair_index*19+13 +: 6]} + 7'd2;
        wire [7:0] vg = {1'b0,previous_sum[pair_index*19+6 +: 7]} +
                       {1'b0,current_sum[pair_index*19+6 +: 7]} + 8'd2;
        wire [6:0] vb = {1'b0,previous_sum[pair_index*19 +: 6]} +
                       {1'b0,current_sum[pair_index*19 +: 6]} + 7'd2;
        assign reduced_pixels[pair_index*16 +: 16] = {vr[6:2],vg[7:2],vb[6:2]};
    end endgenerate

    // No reset on the RAM or its read register, allowing block-RAM inference.
    always @(posedge clock) begin
        if (reset_n && !frame_reset && valid_i) begin
            if (!second_row) row_sums[beat_index] <= horizontal_sum;
            else begin
                previous_sum <= row_sums[beat_index];
                current_sum <= horizontal_sum;
            end
        end
    end
    always @(posedge clock or negedge reset_n) begin
        if (!reset_n) begin
            beat_index <= 0;
            pending_valid <= 1'b0;
            pending_odd <= 1'b0;
            low_half <= 0;
            data_o <= 0;
            valid_o <= 1'b0;
        end else if (frame_reset) begin
            beat_index <= 0;
            pending_valid <= 1'b0;
            pending_odd <= 1'b0;
            valid_o <= 1'b0;
        end else begin
            valid_o <= 1'b0;
            pending_valid <= valid_i && second_row;
            pending_odd <= beat_index[0];
            if (line_start) beat_index <= 0;
            else if (valid_i)
                beat_index <= beat_index == LINE_BEATS-1 ? 0 : beat_index+1'b1;
            if (pending_valid) begin
                if (!pending_odd) low_half <= reduced_pixels;
                else begin
                    data_o <= {reduced_pixels,low_half};
                    valid_o <= 1'b1;
                end
            end
        end
    end
endmodule
