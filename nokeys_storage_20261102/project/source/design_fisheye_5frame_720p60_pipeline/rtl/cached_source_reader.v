`timescale 1ns/1ps

// Bounded request slots retain partial hits, so a refill for another
// neighbor cannot invalidate already acquired pixels. All outputs stay in
// request order and hold until READY. No unbounded outstanding DDR reads.
module cached_source_reader #(
    parameter integer REQUEST_BITS=3,
    parameter integer REFILL_FORWARD_ENABLE=1,
    parameter integer SOURCE_CAPTURE_REVERSE=0
) (
    input wire clock, reset_n, frame_start_i,
    output wire frame_accept_o,
    input wire [31:0] frame_id_i,
    input wire [1:0] source_bank_i,
    input wire abort_i, source_failed_i, source_complete_i,
    input wire [10:0] source_committed_i,
    input wire request_valid_i, request_inside_i,
    output wire request_ready_o,
    input wire [10:0] request_x_i, request_y_i,
    input wire [7:0] request_tag_i,
    output wire pixel_valid_o,
    input wire pixel_ready_i,
    output wire [63:0] pixels_o,
    output wire [7:0] pixel_tag_o,
    output wire busy_o, refill_active_o,
    output reg error_o,
    output reg [31:0] lookup_hits_o, lookup_misses_o, refill_count_o,
    output wire lookup_valid_o,
    input wire lookup_ready_i,
    output wire [31:0] lookup_frame_o,
    output wire [1:0] lookup_bank_o,
    output wire [10:0] lookup_x_o, lookup_y_o,
    input wire response_valid_i,
    input wire [3:0] response_miss_i,
    input wire [63:0] response_pixels_i,
    output wire [27:0] axi_araddr,
    output wire [3:0] axi_arlen,
    output wire axi_arvalid,
    input wire axi_arready,
    input wire [255:0] axi_rdata,
    input wire axi_rvalid, axi_rlast,
    output wire fill_valid_o,
    input wire fill_ready_i,
    output wire [31:0] fill_frame_o,
    output wire [1:0] fill_bank_o,
    output wire [10:0] fill_x_o, fill_y_o,
    output wire [255:0] fill_pixels_o
);
    localparam NORMAL=3'd0, WAIT_PIPE=3'd1, START_REFILL=3'd2;
    localparam WAIT_REFILL=3'd3, RETRY_REQUEST=3'd4, RETRY_RESPONSE=3'd5, DRAIN_FILL=3'd6;
    localparam integer REQUEST_SLOTS=1<<REQUEST_BITS;
    reg [2:0] state;
    reg [REQUEST_BITS:0] count,pending;
    reg [REQUEST_BITS-1:0] head,tail,pending_head,pending_tail;
    reg [REQUEST_BITS-1:0] pending_slots[0:REQUEST_SLOTS-1];
    reg [10:0] queued_x[0:REQUEST_SLOTS-1],queued_y[0:REQUEST_SLOTS-1];
    reg [7:0] queued_tag[0:REQUEST_SLOTS-1];
    reg [63:0] queued_pixels[0:REQUEST_SLOTS-1];
    reg [3:0] acquired[0:REQUEST_SLOTS-1];
    reg [REQUEST_SLOTS-1:0] returned;
    reg active_frame, cancelled;
    reg [31:0] frame;
    reg [1:0] bank;
    wire refill_busy, refill_done, refill_error;
    wire cancellation_now = cancelled || abort_i || source_failed_i;
    assign busy_o = count != 0 || pending != 0 || refill_busy || state != NORMAL;
    assign frame_accept_o = reset_n && frame_start_i && !busy_o;
    // Retain whole-refill error semantics: do not publish a forwarded head
    // while a second row can still return a malformed beat or be cancelled.
    wire forwarding_safe = !REFILL_FORWARD_ENABLE ||
                           (!refill_busy && !(refill_done && refill_error));
    assign pixel_valid_o = count != 0 && returned[head] && (&acquired[head]) && !cancellation_now && forwarding_safe;
    assign pixels_o = queued_pixels[head];
    assign pixel_tag_o = queued_tag[head];
    wire consume_output = pixel_valid_o && pixel_ready_i;
    assign request_ready_o = reset_n && active_frame && !frame_start_i && !cancellation_now &&
                             state == NORMAL && count < REQUEST_SLOTS && (!request_inside_i || lookup_ready_i);
    wire accept_request = request_valid_i && request_ready_o;
    assign lookup_valid_o = !cancellation_now &&
                            ((accept_request && request_inside_i) || state == RETRY_REQUEST);
    assign lookup_frame_o = frame;
    assign lookup_bank_o = bank;
    assign lookup_x_o = state == RETRY_REQUEST ? queued_x[head] : request_x_i;
    assign lookup_y_o = state == RETRY_REQUEST ? queued_y[head] : request_y_i;
    wire accept_lookup = lookup_valid_o && lookup_ready_i;
    wire [REQUEST_BITS-1:0] lookup_slot = state == RETRY_REQUEST ? head : tail;
    wire receive_response = response_valid_i && pending != 0;
    wire [REQUEST_BITS-1:0] response_slot = pending_slots[pending_head];
    wire [1:0] response_origin = {queued_y[response_slot][0], queued_x[response_slot][0]};
    wire [3:0] missing = ~acquired[head];
    // Validated refill rows already contain the exact RGB565 source values.
    // Forward only the current retained head, without bypassing fill ownership
    // or overwriting any previously acquired neighbor under output backpressure.
    wire receive_refill = REFILL_FORWARD_ENABLE && fill_valid_o && fill_ready_i &&
                          count!=0 && !cancellation_now &&
                          fill_frame_o==frame && fill_bank_o==bank;
    wire [10:0] head_right_x=queued_x[head]+11'd1;
    wire [10:0] head_bottom_y=queued_y[head]+11'd1;
    wire [1:0] head_origin={queued_y[head][0],queued_x[head][0]};
    wire [1:0] refill_columns={fill_x_o[10:4]==head_right_x[10:4],
                              fill_x_o[10:4]==queued_x[head][10:4]};
    wire [1:0] refill_rows={fill_y_o==head_bottom_y,fill_y_o==queued_y[head]};
    wire [3:0] refill_order_mask={refill_rows[1]&&refill_columns[1],refill_rows[1]&&refill_columns[0],
                                  refill_rows[0]&&refill_columns[1],refill_rows[0]&&refill_columns[0]};
    // Acquired bits are parity-bank ordered; queued pixels are TL/TR/BL/BR.
    wire [3:0] refill_parity_mask={refill_order_mask[head_origin^2'd3],refill_order_mask[head_origin^2'd2],
                                   refill_order_mask[head_origin^2'd1],refill_order_mask[head_origin]};
    wire [15:0] refill_left_pixel=fill_pixels_o[queued_x[head][3:0]*16+:16];
    wire [15:0] refill_right_pixel=fill_pixels_o[head_right_x[3:0]*16+:16];
    wire [1:0] first_missing = missing[0] ? 2'd0 : missing[1] ? 2'd1 : missing[2] ? 2'd2 : 2'd3;
    wire [10:0] refill_pixel_x = queued_x[head] + (queued_x[head][0] != first_missing[0]);
    wire [10:0] refill_pixel_y = queued_y[head] + (queued_y[head][0] != first_missing[1]);
    assign refill_active_o = state != NORMAL || refill_busy;
    source_block_refill #(.SOURCE_CAPTURE_REVERSE(SOURCE_CAPTURE_REVERSE)) refill (
        .clock(clock), .reset_n(reset_n), .start_i(state==START_REFILL && !cancellation_now),
        .abort_i(cancellation_now), .frame_id_i(frame), .source_bank_i(bank),
        .source_x_i({refill_pixel_x[10:4],4'd0}), .source_y_i({refill_pixel_y[10:1],1'b0}),
        .source_committed_i(source_committed_i), .source_complete_i(source_complete_i),
        .source_failed_i(source_failed_i), .busy_o(refill_busy), .done_o(refill_done), .error_o(refill_error),
        .axi_araddr(axi_araddr), .axi_arlen(axi_arlen), .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rdata(axi_rdata), .axi_rvalid(axi_rvalid), .axi_rlast(axi_rlast),
        .fill_valid_o(fill_valid_o), .fill_ready_i(fill_ready_i), .fill_frame_o(fill_frame_o),
        .fill_bank_o(fill_bank_o), .fill_x_o(fill_x_o), .fill_y_o(fill_y_o), .fill_pixels_o(fill_pixels_o)
    );

    // Each retained slot has a constant write target. A new request overrides
    // an old response exactly as in the original sequential statement order.
    // Responses still update during cancellation while accepted lookups drain.
    genvar slot;
    generate for(slot=0;slot<REQUEST_SLOTS;slot=slot+1)begin: retained_slot
        integer neighbor;
        always @(posedge clock)begin
            if(!reset_n||frame_accept_o)begin
                queued_x[slot]<=0;queued_y[slot]<=0;queued_tag[slot]<=0;
                queued_pixels[slot]<=0;acquired[slot]<=0;pending_slots[slot]<=0;
            end else begin
                if(accept_lookup&&pending_tail==slot)pending_slots[slot]<=lookup_slot;
                if((receive_response&&response_slot==slot)||(receive_refill&&head==slot))
                    acquired[slot]<=acquired[slot]|
                        ((receive_response&&response_slot==slot)?~response_miss_i:4'd0)|
                        ((receive_refill&&head==slot)?refill_parity_mask:4'd0);
                if(receive_response&&response_slot==slot)begin
                    for(neighbor=0;neighbor<4;neighbor=neighbor+1)
                        if(!response_miss_i[response_origin^neighbor[1:0]]&&
                           !acquired[slot][response_origin^neighbor[1:0]])
                            queued_pixels[slot][neighbor*16+:16]<=response_pixels_i[neighbor*16+:16];
                end
                if(receive_refill&&head==slot)begin
                    for(neighbor=0;neighbor<4;neighbor=neighbor+1)
                        if(refill_order_mask[neighbor]&&!acquired[slot][head_origin^neighbor[1:0]])
                            queued_pixels[slot][neighbor*16+:16]<=neighbor[0]?refill_right_pixel:refill_left_pixel;
                end
                if(accept_request)begin
                    if(tail==slot)begin
                        queued_x[slot]<=request_x_i;queued_y[slot]<=request_y_i;queued_tag[slot]<=request_tag_i;
                        queued_pixels[slot]<=0;acquired[slot]<=request_inside_i?4'd0:4'hf;
                    end
                end
            end
        end
    end endgenerate

    always @(posedge clock) begin
        if (!reset_n || frame_accept_o) begin
            state <= NORMAL; count <= 0; pending <= 0; head <= 0; tail <= 0;
            pending_head <= 0; pending_tail <= 0; returned <= 0;
            active_frame <= reset_n; cancelled <= 0; error_o <= 0;
            frame <= frame_id_i; bank <= source_bank_i;
            lookup_hits_o <= 0; lookup_misses_o <= 0; refill_count_o <= 0;
        end else begin
            if (frame_start_i && busy_o) error_o <= 1;
            if (response_valid_i && pending == 0) begin error_o <= 1; cancelled <= 1; end
            case ({accept_lookup,receive_response})
                2'b10: pending <= pending + 1'b1;
                2'b01: pending <= pending - 1'b1;
                default: begin end
            endcase
            if (accept_lookup) begin
                pending_tail <= pending_tail + 1'b1;
            end
            if (receive_response) begin
                pending_head <= pending_head + 1'b1;
                returned[response_slot] <= 1'b1;
                if (&(~response_miss_i)) lookup_hits_o <= lookup_hits_o + 1'b1;
                else lookup_misses_o <= lookup_misses_o + 1'b1;
            end
            if (cancellation_now || refill_done && refill_error) begin
                cancelled <= 1; active_frame <= 0;
                if (source_failed_i || refill_done && refill_error) error_o <= 1;
                // Accepted address/data operations remain owned until drained.
                if (pending == 0 && !refill_busy) begin
                    state <= NORMAL; count <= 0; head <= 0; tail <= 0; returned <= 0;
                    pending_head <= 0; pending_tail <= 0;
                end
            end else begin
                case ({accept_request,consume_output})
                    2'b10: count <= count + 1'b1;
                    2'b01: count <= count - 1'b1;
                    default: begin end
                endcase
                if (accept_request) begin
                    returned[tail] <= !request_inside_i; tail <= tail + 1'b1;
                    if (request_inside_i && (request_x_i>=1279 || request_y_i>=719)) begin
                        error_o <= 1; cancelled <= 1;
                    end
                end
                if (consume_output) begin returned[head] <= 0; head <= head + 1'b1; end
                case (state)
                    NORMAL: if (count!=0 && returned[head] && !( &acquired[head])) state<=WAIT_PIPE;
                    // Earlier queued requests can have repaired this block
                    // after the stored miss response. Recheck before reading DDR.
                    WAIT_PIPE: if (pending==0) state<=RETRY_REQUEST;
                    START_REFILL: begin state<=WAIT_REFILL; refill_count_o<=refill_count_o+1'b1; end
                    WAIT_REFILL: if (refill_done) begin
                        // A forwarded head can retire while its refill drains.
                        // Empty queues must not issue an unowned retry lookup.
                        if(REFILL_FORWARD_ENABLE&&(count==0||(&acquired[head])||(count==1&&consume_output)))state<=DRAIN_FILL;
                        else state<=RETRY_REQUEST;
                    end
                    // Cache publication remains owned until its final commit.
                    // Then recheck the current head, which may have advanced.
                    DRAIN_FILL: if(lookup_ready_i)begin
                        if(count!=0&&!(&acquired[head]))state<=RETRY_REQUEST;
                        else state<=NORMAL;
                    end
                    RETRY_REQUEST: if (accept_lookup) state<=RETRY_RESPONSE;
                    RETRY_RESPONSE: if (receive_response) begin
                        if ((acquired[response_slot] | ~response_miss_i)==4'hf) state<=NORMAL;
                        else state<=START_REFILL;
                    end
                    default: begin cancelled<=1;error_o<=1;end
                endcase
            end
        end
    end
endmodule
