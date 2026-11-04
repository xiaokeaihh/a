`timescale 1ns/1ps

// Configurable small coordinate contexts replace full-ROI A/B transfers. Geometry,
// source repair and COR archive run independently. This stage still archives
// the complete image; live HDMI ownership is integrated separately.
module shared_pipeline_renderer #(
    parameter integer TILE_ROW_BITS=3,
    parameter integer CONTEXT_BITS=2,
    parameter integer REQUEST_BITS=2,
    // -1 selects camera-friendly order from the locked pose; 0/1 force order.
    parameter integer SCAN_REVERSE=-1,
    parameter integer CACHE_SET_BITS=7,
    parameter integer SOURCE_CAPTURE_REVERSE=0,
    parameter integer ACTIVE_MATRIX_FOR_CENTER=0
) (
    input wire source_reverse_i,
    input wire clock, reset_n, start_i,
    input wire abort_i,
    input wire [31:0] frame_id_i,
    input wire [1:0] source_bank_i, destination_bank_i,
    input wire [2:0] view_i,
    input wire [287:0] matrix_i,
    input wire [1439:0] views_i,
    input wire source_complete_i, source_failed_i,
    input wire [10:0] source_committed_i,
    output wire busy_o,
    output reg done_o, error_o,output reg [5:0] error_reason_o,
    output reg [543:0] counters_o,
    output wire dependencies_ready_o,
    output wire [159:0] cache_stats_o,
    output reg [10:0] rows_committed_o,
    output reg progress_valid_o,
    input wire tap_valid_i,
    input wire [31:0] tap_frame_i,
    input wire [1:0] tap_bank_i,
    input wire [10:0] tap_x_i,tap_y_i,
    input wire [255:0] tap_pixels_i,
    output wire [27:0] axi_araddr,axi_awaddr,
    output wire [3:0] axi_arlen,axi_arid,axi_awlen,axi_awid,
    output wire axi_arvalid,axi_awvalid,
    input wire axi_arready,axi_awready,
    input wire [255:0] axi_rdata,
    input wire axi_rvalid,axi_rlast,
    output wire [255:0] axi_wdata,
    output wire [31:0] axi_wstrb,
    input wire axi_wready,axi_wlast
);
    wire source_reverse = source_reverse_i === 1'b1 || (source_reverse_i !== 1'b0 && SOURCE_CAPTURE_REVERSE != 0);
    localparam G_IDLE=0,G_INIT=1,G_ISSUE=2,G_DRAIN=3,G_ENQUEUE=4;
    localparam P_IDLE=0,P_ISSUE=1,P_DRAIN=2;
    localparam integer TILE_ROWS=1<<TILE_ROW_BITS;
    localparam integer TASK_INDEX_BITS=4+TILE_ROW_BITS;
    localparam integer TASK_PIXELS=16*TILE_ROWS;
    localparam integer CONTEXTS=1<<CONTEXT_BITS;
    reg [10:0] global_required;

    localparam integer STRIPES=720/TILE_ROWS;
    localparam integer STRIPE_BITS=TILE_ROW_BITS==2 ? 8 : 7;
    reg running,aborting,geometry_finished;
    assign dependencies_ready_o=geometry_finished&&(source_complete_i||source_committed_i>=global_required);
    reg [2:0] geometry_state;
    reg [1:0] pixel_state;
    reg [2:0] frame_view;
    reg [10:0] output_width,output_height;
    reg [9:0] output_stride;
    reg [287:0] baseline,projection_matrix;
    reg [1439:0] views;
    reg [31:0] front_frame;
    reg [10:0] geometry_x,geometry_y,target_x,target_y;
    reg [CONTEXT_BITS-1:0] geometry_slot,pixel_slot;
    reg [TASK_INDEX_BITS-1:0] geometry_input;
    reg [TASK_INDEX_BITS:0] geometry_received,coordinate_issued,source_accepted,pixel_received;
    reg [10:0] required_lines;
    reg [31:0] sequence_deadline;
    reg [2:0] completed_stripe_jobs;
    reg [10:0] expected_commit_x,expected_commit_y;
    reg geometry_reverse,scan_reverse;
    reg [STRIPES-1:0] committed_stripes;
    reg [STRIPE_BITS-1:0] scan_stripe;
    wire launch_reverse=SCAN_REVERSE<0 ? (matrix_i[159] ^ (source_reverse)) : SCAN_REVERSE!=0;
    reg [40:0] coordinates[0:CONTEXTS*TASK_PIXELS-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [40:0] coordinate;
    reg coordinate_valid;
    reg [21:0] coordinate_position;
    reg [2:0] metadata_tail;
    reg [38:0] metadata[0:7];
    reg [21:0] position_d1,position_d2;
    wire launch=start_i&&!running;
    wire active_reset=reset_n&&running&&!aborting;
    assign busy_o=running;
    assign axi_arid=1;

    function [31:0] magnitude;
        input [31:0] value;
        begin magnitude=value[31] ? (~value+1'b1) : value; end
    endfunction
    wire column_major=magnitude(matrix_i[3*32+:32])>magnitude(matrix_i[0*32+:32]);
    wire [10:0] projection_x=frame_view==5 ?
        (geometry_x+geometry_input[3:0]>=640 ? geometry_x+geometry_input[3:0]-11'd640 : geometry_x+geometry_input[3:0]) :
        geometry_x+geometry_input[3:0];
    wire [10:0] projection_y=frame_view==5 ?
        (geometry_y+(geometry_input>>4)>=360 ? geometry_y+(geometry_input>>4)-11'd360 : geometry_y+(geometry_input>>4)) :
        geometry_y+(geometry_input>>4);
    wire projection_valid,projection_inside;
    wire [19:0] source_x,source_y;
    wire [10:0] projected_capture_requirement=source_reverse ?
        11'd720-source_y[18:8] : source_y[18:8]+11'd2;
    stabilized_projection projection (
        .clock(clock),.reset_n(active_reset),.input_valid_i(geometry_state==G_ISSUE&&!aborting),
        .output_x_i(projection_x),.output_y_i(projection_y),.canvas_valid_i(1'b1),
        .matrix_i(projection_matrix),.output_valid_o(projection_valid),.inside_o(projection_inside),
        .source_x_q8_o(source_x),.source_y_q8_o(source_y)
    );

    wire enqueue_ready,queue_error,grant_valid,grant_ready,grant_overdue;
    wire [CONTEXT_BITS-1:0] enqueue_slot,grant_slot;
    wire [CONTEXTS-1:0] task_valid,source_ready,reserved;
    wire [CONTEXTS*128-1:0] descriptors;
    wire [CONTEXTS*32-1:0] deadlines;
    wire [127:0] grant_descriptor=descriptors[grant_slot*128+:128];
    wire [127:0] pixel_descriptor=descriptors[pixel_slot*128+:128];
    wire [10:0] pixel_x0=pixel_descriptor[10:0],pixel_y0=pixel_descriptor[21:11];
    reg complete_task;
    wire [127:0] enqueue_descriptor={106'd0,geometry_y,geometry_x};
    wire [CONTEXTS-1:0] free_contexts=~task_valid;
    reg [CONTEXT_BITS-1:0] first_free_context;
    integer fc;
    always @* begin
        first_free_context=0;
        for(fc=CONTEXTS-1;fc>=0;fc=fc-1)if(free_contexts[fc])first_free_context=fc;
    end
    // Geometry owns its selected free context until enqueue. A lower context
    // becoming free meanwhile must not redirect its descriptor to another RAM.
    task_descriptor_queue #(.USE_SLOT_HINT(1),.SLOT_BITS(CONTEXT_BITS)) tasks (
        .clock(clock),.reset_n(reset_n),.frame_start_i(launch),.frame_id_i(frame_id_i),.abort_i(aborting),
        .enqueue_valid_i(geometry_state==G_ENQUEUE&&!aborting),.enqueue_frame_i(front_frame),
        .enqueue_descriptor_i(enqueue_descriptor),.enqueue_deadline_i(sequence_deadline),.enqueue_required_i(required_lines),
        .enqueue_slot_i(geometry_state==G_IDLE ? first_free_context : geometry_slot),
        .enqueue_ready_o(enqueue_ready),.enqueue_slot_o(enqueue_slot),
        .source_committed_i(source_committed_i),.source_complete_i(source_complete_i),
        .reserve_i(grant_valid&&grant_ready),.reserve_slot_i(grant_slot),
        .complete_i(complete_task),.complete_slot_i(pixel_slot),
        .valid_o(task_valid),.reserved_o(reserved),.source_ready_o(source_ready),
        .descriptors_o(descriptors),.deadlines_o(deadlines),.error_o(queue_error)
    );
    wire [CONTEXTS-1:0] output_space;
    ready_task_scheduler #(.SLOT_BITS(CONTEXT_BITS)) scheduler (
        .clock(clock),.reset_n(reset_n),.cancel_i(launch||aborting||!running),
        .task_valid_i(task_valid&~reserved),.source_ready_i(source_ready),.output_space_i(output_space),
        .deadlines_i(deadlines),.now_i(32'd0),.grant_valid_o(grant_valid),.grant_ready_i(grant_ready),
        .grant_slot_o(grant_slot),.overdue_o(grant_overdue)
    );

    wire source_ready_for_pixel,source_pixel_valid,frontend_busy,frontend_error,frontend_frame_accept;
    wire [63:0] neighbors;
    wire [7:0] source_tag;
    wire accept_source=coordinate_valid&&source_ready_for_pixel&&!aborting;
    wire read_coordinate=pixel_state==P_ISSUE&&coordinate_issued<TASK_PIXELS&&(!coordinate_valid||accept_source)&&!aborting;
    wire [TASK_INDEX_BITS+CONTEXT_BITS-1:0] coordinate_address={pixel_slot,coordinate_issued[TASK_INDEX_BITS-1:0]};
    wire [10:0] output_pixel_x=pixel_x0+{7'd0,coordinate_issued[3:0]};
    wire [10:0] output_pixel_y=pixel_y0+(coordinate_issued>>4);
    wire [31:0] hits,misses,refills,tap_accepted,tap_dropped;
    wire [4:0] frontend_activity;
    wire [1:0] writer_activity;
    assign cache_stats_o={tap_dropped,tap_accepted,refills,misses,hits};
    cutthrough_source_frontend #(.CACHE_SET_BITS(CACHE_SET_BITS),.REQUEST_BITS(REQUEST_BITS),
        .SOURCE_CAPTURE_REVERSE(SOURCE_CAPTURE_REVERSE)) frontend (
        .source_reverse_i(source_reverse_i),.clock(clock),.reset_n(reset_n),.frame_start_i(launch),.frame_accept_o(frontend_frame_accept),
        .frame_id_i(frame_id_i),.source_bank_i(source_bank_i),.column_major_i(column_major),
        // The core latches every RAW failure into aborting/error_o. Use that
        // registered cancellation for all owned frontend transactions, instead
        // of a parallel bank-select -> raw_failed -> fill/tag-enable path.
        // Banks remain owned until the announced DDR transaction drains.
        .abort_i(aborting),.source_failed_i(1'b0),.source_complete_i(source_complete_i),
        .source_committed_i(source_committed_i),.request_valid_i(coordinate_valid&&!aborting),
        .request_inside_i(coordinate[40]),.request_ready_o(source_ready_for_pixel),
        .request_x_i(coordinate[18:8]),.request_y_i(coordinate[38:28]),.request_tag_i({5'd0,metadata_tail}),
        .pixel_valid_o(source_pixel_valid),.pixel_ready_i(running&&!aborting),.pixels_o(neighbors),.pixel_tag_o(source_tag),
        .activity_o(frontend_activity),.busy_o(frontend_busy),.error_o(frontend_error),.lookup_hits_o(hits),.lookup_misses_o(misses),
        .refill_count_o(refills),.tap_accepted_o(tap_accepted),.tap_dropped_o(tap_dropped),
        .tap_valid_i(tap_valid_i),.tap_frame_i(tap_frame_i),.tap_bank_i(tap_bank_i),
        .tap_x_i(tap_x_i),.tap_y_i(tap_y_i),.tap_pixels_i(tap_pixels_i),
        .axi_araddr(axi_araddr),.axi_arlen(axi_arlen),.axi_arvalid(axi_arvalid),.axi_arready(axi_arready),
        .axi_rdata(axi_rdata),.axi_rvalid(axi_rvalid),.axi_rlast(axi_rlast)
    );
    wire [38:0] returned_metadata=metadata[source_tag[2:0]];
    wire pixel_valid;
    wire [15:0] pixel;
    bilinear_rgb565 interpolation (
        .clock(clock),.reset_n(active_reset),.pixel_valid_i(source_pixel_valid&&!aborting),
        .neighborhood_valid_i(returned_metadata[38]),.source_pixels_flat(neighbors),
        .fractional_x(returned_metadata[7:0]),.fractional_y(returned_metadata[15:8]),
        .pixel_valid_o(pixel_valid),.corrected_pixel(pixel)
    );

    wire writer_ready,writer_idle,writer_error,write_wait;
    wire stripe_commit;
    wire [10:0] stripe_x,stripe_y;
    wire [4:0] stripe_height;
    assign grant_ready=running&&!aborting&&pixel_state==P_IDLE&&writer_ready;
    compact_stripe_writer #(.STRIPE_ROW_BITS(TILE_ROW_BITS),.TASK_SLOTS(CONTEXTS)) writer (
        .clock(clock),.reset_n(reset_n),.frame_start_i(launch),.abort_i(aborting&&!launch),
        .frame_base_i(28'h0180000+{7'd0,destination_bank_i,19'd0}),
        .frame_height_i((view_i<5||view_i==6)?11'd360:11'd720),.reverse_i(launch_reverse),
        .task_descriptors_i(descriptors),.task_space_o(output_space),.activity_o(writer_activity),
        .stride_words_i((view_i<5||view_i==6)?10'd320:10'd640),
        .tile_start_i(grant_valid&&grant_ready),.tile_x_i(grant_descriptor[10:0]),
        .grid_y_i(grant_descriptor[21:11]),.grid_height_i(TILE_ROWS[4:0]),.tile_ready_o(writer_ready),
        .pixel_valid_i(pixel_valid&&!aborting),.pixel_i(pixel),
        .pixel_x_i(position_d2[10:0]),.pixel_y_i(position_d2[21:11]),
        .idle_o(writer_idle),.error_o(writer_error),
        .axi_awaddr(axi_awaddr),.axi_awlen(axi_awlen),.axi_awid(axi_awid),.axi_awvalid(axi_awvalid),.axi_awready(axi_awready),
        .axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),.axi_wlast(axi_wlast),.write_wait_o(write_wait),
        .stripe_commit_o(stripe_commit),.stripe_x_o(stripe_x),.stripe_y_o(stripe_y),.stripe_height_o(stripe_height)
    );

    always @(posedge clock)begin
        if(read_coordinate)begin
            coordinate<=coordinates[coordinate_address];
            coordinate_position<={output_pixel_y,output_pixel_x};
        end
        if(!active_reset)begin coordinate_valid<=0;metadata_tail<=0;position_d1<=0;position_d2<=0;end
        else begin
            if(!coordinate_valid||accept_source)coordinate_valid<=read_coordinate;
            if(accept_source)begin
                metadata[metadata_tail]<={coordinate[40],coordinate_position,coordinate[27:20],coordinate[7:0]};
                metadata_tail<=metadata_tail+1'b1;
            end
            if(source_pixel_valid)position_d1<=returned_metadata[37:16];
            position_d2<=position_d1;
        end
    end

    always @(posedge clock)begin
        if(!reset_n)begin
            running<=0;aborting<=0;done_o<=0;error_o<=0;error_reason_o<=0;geometry_finished<=0;
            geometry_state<=G_IDLE;pixel_state<=P_IDLE;complete_task<=0;front_frame<=0;counters_o<=0;global_required<=0;
            geometry_x<=0;geometry_y<=0;target_x<=0;target_y<=0;completed_stripe_jobs<=0;
            rows_committed_o<=0;progress_valid_o<=0;expected_commit_x<=0;expected_commit_y<=0;
        end else begin
            done_o<=0;complete_task<=0;progress_valid_o<=0;
            if(launch)begin
                running<=1;aborting<=0;error_o<=0;error_reason_o<=0;geometry_finished<=0;front_frame<=frame_id_i;
                frame_view<=view_i;baseline<=matrix_i;views<=views_i;
                output_width<=(view_i<5||view_i==6)?640:1280;output_height<=(view_i<5||view_i==6)?360:720;
                output_stride<=(view_i<5||view_i==6)?320:640;
                geometry_state<=G_IDLE;pixel_state<=P_IDLE;
                geometry_x<=0;target_x<=0;completed_stripe_jobs<=0;sequence_deadline<=0;
                geometry_reverse<=launch_reverse;committed_stripes<=0;
                scan_reverse<=source_reverse;
                scan_stripe<=source_reverse ? ((view_i<5||view_i==6)?360:720)/TILE_ROWS-1 : 0;
                geometry_y<=launch_reverse ? ((view_i<5||view_i==6)?360:720)-TILE_ROWS : 0;
                target_y<=launch_reverse ? ((view_i<5||view_i==6)?360:720)-TILE_ROWS : 0;
                expected_commit_x<=0;rows_committed_o<=0;
                expected_commit_y<=launch_reverse ? ((view_i<5||view_i==6)?360:720)-TILE_ROWS : 0;
                coordinate_issued<=0;source_accepted<=0;pixel_received<=0;counters_o<=0;global_required<=0;
            end else if(running)begin
                // A tiny completion bitmap separates camera-friendly compute
                // order from each input bank's display-row order. Advance at one
                // stripe/clock, avoiding a 90-entry combinational priority tree.
                if(!aborting&&rows_committed_o<output_height&&committed_stripes[scan_stripe])begin
                    rows_committed_o<=rows_committed_o+TILE_ROWS;
                    scan_stripe<=scan_reverse ? scan_stripe-1'b1 : scan_stripe+1'b1;progress_valid_o<=1;
                end
                counters_o[0+:32]<=counters_o[0+:32]+1'b1;
                if(geometry_state!=G_IDLE)counters_o[32+:32]<=counters_o[32+:32]+1'b1;
                if(geometry_state==G_IDLE&&!geometry_finished&&!enqueue_ready)counters_o[64+:32]<=counters_o[64+:32]+1'b1;
                if((|(task_valid&~reserved&output_space))&&!(|(source_ready&output_space)))counters_o[96+:32]<=counters_o[96+:32]+1'b1;
                if(axi_arvalid&&!axi_arready)counters_o[128+:32]<=counters_o[128+:32]+1'b1;
                if(coordinate_valid&&!source_ready_for_pixel)counters_o[192+:32]<=counters_o[192+:32]+1'b1;
                if(write_wait)counters_o[224+:32]<=counters_o[224+:32]+1'b1;
                if(frontend_activity[0])counters_o[160+:32]<=counters_o[160+:32]+1'b1;
                if((|(task_valid&~reserved&source_ready))&&!(|(task_valid&~reserved&source_ready&output_space)))counters_o[320+:32]<=counters_o[320+:32]+1'b1;
                if(frontend_activity[1])counters_o[352+:32]<=counters_o[352+:32]+1'b1;
                if(frontend_activity[2])counters_o[384+:32]<=counters_o[384+:32]+1'b1;
                if(writer_activity[0])counters_o[416+:32]<=counters_o[416+:32]+1'b1;
                if(writer_activity[1])counters_o[448+:32]<=counters_o[448+:32]+1'b1;
                if(pixel_state==P_IDLE&&!geometry_finished)counters_o[480+:32]<=counters_o[480+:32]+1'b1;
                if(frontend_activity[4])counters_o[512+:32]<=counters_o[512+:32]+1'b1;
                if(pixel_valid)counters_o[288+:32]<=counters_o[288+:32]+1'b1;
                if(source_failed_i||(abort_i===1'b1)||frontend_error||queue_error||writer_error)begin
                    aborting<=1;error_o<=1;
                    error_reason_o[4:0]<=error_reason_o[4:0]|{writer_error,queue_error,frontend_error,abort_i===1'b1,source_failed_i};
                end
                if(stripe_commit&&!aborting)begin
                    if(stripe_x!=expected_commit_x||stripe_y!=expected_commit_y||stripe_height!=TILE_ROWS)begin
                        aborting<=1;error_o<=1;error_reason_o[5]<=1;
                    end else if(expected_commit_x==output_width-128)begin
                        expected_commit_x<=0;committed_stripes[stripe_y>>TILE_ROW_BITS]<=1;
                        expected_commit_y<=geometry_reverse ? expected_commit_y-TILE_ROWS : expected_commit_y+TILE_ROWS;
                    end else expected_commit_x<=expected_commit_x+128;
                end
                if(aborting)begin
                    if(!frontend_busy&&pixel_state!=P_IDLE)begin complete_task<=1;pixel_state<=P_IDLE;end
                    if(!frontend_busy&&writer_idle&&!(|task_valid)&&pixel_state==P_IDLE)begin
                        running<=0;done_o<=1;geometry_state<=G_IDLE;
                    end
                end else begin
                    case(geometry_state)
                        G_IDLE:if(!geometry_finished&&enqueue_ready)begin geometry_slot<=enqueue_slot;geometry_state<=G_INIT;end
                        G_INIT:begin
                            case(frame_view)
                                1:projection_matrix<=views[0+:288];2:projection_matrix<=views[288+:288];
                                3:projection_matrix<=views[576+:288];4:projection_matrix<=views[864+:288];
                                6:projection_matrix<=ACTIVE_MATRIX_FOR_CENTER?baseline:views[1152+:288];
                                5:case({geometry_y>=360,geometry_x>=640})
                                    2'b00:projection_matrix<=views[576+:288];2'b01:projection_matrix<=views[864+:288];
                                    2'b10:projection_matrix<=views[0+:288];default:projection_matrix<=views[288+:288];
                                endcase
                                default:projection_matrix<=baseline;
                            endcase
                            geometry_input<=0;geometry_received<=0;required_lines<=0;geometry_state<=G_ISSUE;
                        end
                        G_ISSUE:if(geometry_input==TASK_PIXELS-1)geometry_state<=G_DRAIN;else geometry_input<=geometry_input+1'b1;
                        G_DRAIN:if(projection_valid&&geometry_received==TASK_PIXELS-1)geometry_state<=G_ENQUEUE;
                        G_ENQUEUE:if(enqueue_ready)begin
                            geometry_state<=G_IDLE;sequence_deadline<=sequence_deadline+TASK_PIXELS;
                            if(geometry_x==output_width-16)begin
                                geometry_x<=0;
                                if(geometry_reverse ? geometry_y==0 : geometry_y==output_height-TILE_ROWS)geometry_finished<=1;
                                else geometry_y<=geometry_reverse ? geometry_y-TILE_ROWS : geometry_y+TILE_ROWS;
                            end else geometry_x<=geometry_x+16;
                        end
                    endcase
                    if((geometry_state==G_ISSUE||geometry_state==G_DRAIN)&&projection_valid)begin
                        coordinates[{geometry_slot,geometry_received[TASK_INDEX_BITS-1:0]}]<={projection_inside,source_y,source_x};
                        geometry_received<=geometry_received+1'b1;
                        if(projection_inside&&projected_capture_requirement>required_lines)required_lines<=projected_capture_requirement;
                        if(projection_inside&&projected_capture_requirement>global_required)global_required<=projected_capture_requirement;
                    end
                    case(pixel_state)
                        P_IDLE:if(grant_valid&&grant_ready)begin
                            pixel_slot<=grant_slot;coordinate_issued<=0;source_accepted<=0;pixel_received<=0;pixel_state<=P_ISSUE;
                        end
                        P_ISSUE:begin
                            if(read_coordinate)coordinate_issued<=coordinate_issued+1'b1;
                            if(accept_source)begin
                                source_accepted<=source_accepted+1'b1;
                                if(source_accepted==TASK_PIXELS-1)pixel_state<=P_DRAIN;
                            end
                        end
                    endcase
                    if(pixel_valid)begin
                        pixel_received<=pixel_received+1'b1;
                        if(pixel_received==TASK_PIXELS-1)begin
                            complete_task<=1;pixel_state<=P_IDLE;

                        end
                    end
                    if(geometry_finished&&!(|task_valid)&&pixel_state==P_IDLE&&writer_idle&&!frontend_busy&&source_complete_i&&rows_committed_o==output_height)begin
                        running<=0;done_o<=1;
                    end
                end
            end
        end
    end
endmodule
