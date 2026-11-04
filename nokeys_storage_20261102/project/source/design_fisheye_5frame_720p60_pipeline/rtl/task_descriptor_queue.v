`timescale 1ns/1ps

// Four task contexts. Issuing reserves a context; only explicit completion
// releases it, including on abort. REQUIRED is the maximum source line count
// over every actual valid coordinate plus its bottom bilinear neighbor.
module task_descriptor_queue #(
    parameter integer USE_SLOT_HINT=0,
    parameter integer SLOT_BITS=2
) (
    input wire clock, reset_n, frame_start_i, abort_i,
    input wire [31:0] frame_id_i,
    input wire enqueue_valid_i,
    input wire [31:0] enqueue_frame_i,
    input wire [127:0] enqueue_descriptor_i,
    input wire [31:0] enqueue_deadline_i,
    input wire [10:0] enqueue_required_i,
    input wire [SLOT_BITS-1:0] enqueue_slot_i,
    output wire enqueue_ready_o,
    output wire [SLOT_BITS-1:0] enqueue_slot_o,
    input wire [10:0] source_committed_i,
    input wire source_complete_i,
    input wire reserve_i,
    input wire [SLOT_BITS-1:0] reserve_slot_i,
    input wire complete_i,
    input wire [SLOT_BITS-1:0] complete_slot_i,
    output reg [(1<<SLOT_BITS)-1:0] valid_o, reserved_o,
    output wire [(1<<SLOT_BITS)-1:0] source_ready_o,
    output wire [(32<<SLOT_BITS)-1:0] deadlines_o,
    output wire [(128<<SLOT_BITS)-1:0] descriptors_o,
    output reg error_o
);
    reg active;
    reg [31:0] frame;
    reg [127:0] descriptors[0:(1<<SLOT_BITS)-1];
    reg [31:0] deadlines[0:(1<<SLOT_BITS)-1];
    reg [10:0] required_lines[0:(1<<SLOT_BITS)-1];
    wire [(1<<SLOT_BITS)-1:0] free_slots = ~valid_o;
    reg [SLOT_BITS-1:0] first_free;
    reg [(1<<SLOT_BITS)-1:0] first_free_onehot;
    integer candidate;
    always @* begin
        first_free=0;first_free_onehot=0;
        for(candidate=(1<<SLOT_BITS)-1;candidate>=0;candidate=candidate-1)
            if(free_slots[candidate])begin first_free=candidate;first_free_onehot=(1'b1<<candidate);end
    end
    wire [(1<<SLOT_BITS)-1:0] selected_free = USE_SLOT_HINT ?
        (({{((1<<SLOT_BITS)-1){1'b0}},1'b1}<<enqueue_slot_i)&free_slots) : first_free_onehot;
    wire enqueue_allowed = reset_n && active && !abort_i && !frame_start_i && enqueue_frame_i==frame;
    // Encode only the public slot number. Storage write enables stay one-hot,
    // avoiding priority encode -> indexed free test -> address decode.
    wire [(1<<SLOT_BITS)-1:0] enqueue_writes = selected_free & {(1<<SLOT_BITS){enqueue_valid_i && enqueue_allowed}};
    assign enqueue_slot_o=USE_SLOT_HINT ? enqueue_slot_i : first_free;
    assign enqueue_ready_o = enqueue_allowed && (|selected_free);
    genvar slot;
    generate for(slot=0;slot<(1<<SLOT_BITS);slot=slot+1)begin: expose
        assign source_ready_o[slot] = active && !abort_i && valid_o[slot] && !reserved_o[slot] &&
                                     (source_complete_i || source_committed_i>=required_lines[slot]);
        assign deadlines_o[slot*32+:32] = deadlines[slot];
        assign descriptors_o[slot*128+:128] = descriptors[slot];
    end endgenerate
    integer slot_number;
    always @(posedge clock) begin
        if(!reset_n || frame_start_i && !(|valid_o))begin
            active <= reset_n;frame <= frame_id_i;valid_o <= 0;reserved_o <= 0;error_o <= 0;
            for(slot_number=0;slot_number<(1<<SLOT_BITS);slot_number=slot_number+1)begin
                descriptors[slot_number] <= 0;deadlines[slot_number] <= 0;required_lines[slot_number] <= 0;
            end
        end else begin
            if(frame_start_i && (|valid_o))error_o <= 1;
            if(abort_i)begin active <= 0;valid_o <= reserved_o;end
            for(slot_number=0;slot_number<(1<<SLOT_BITS);slot_number=slot_number+1)begin
                if(enqueue_writes[slot_number])begin
                    valid_o[slot_number] <= 1;
                    descriptors[slot_number] <= enqueue_descriptor_i;
                    deadlines[slot_number] <= enqueue_deadline_i;
                    required_lines[slot_number] <= enqueue_required_i;
                end
            end
            if(enqueue_valid_i && enqueue_ready_o && enqueue_required_i>720)error_o <= 1;
            if(reserve_i && !abort_i)begin
                if(source_ready_o[reserve_slot_i])reserved_o[reserve_slot_i] <= 1;
                else error_o <= 1;
            end
            if(complete_i)begin
                if(reserved_o[complete_slot_i])begin
                    reserved_o[complete_slot_i] <= 0;valid_o[complete_slot_i] <= 0;
                end else error_o <= 1;
            end
        end
    end
endmodule
