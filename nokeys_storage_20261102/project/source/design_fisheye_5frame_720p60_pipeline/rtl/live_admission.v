`timescale 1ns/1ps

// A bounded affine producer envelope, not a first-line-ready heuristic.
// Partial admission requires a geometry/service certificate. Unknown poses
// use the complete-image fallback. Runtime over-budget scans become faults.
module live_admission #(
    parameter integer MAX_ROW_CYCLES=16384,
    parameter integer SCAN_LINE_CYCLES=2777,
    parameter integer FETCH_MARGIN_CYCLES=4096
) (
    input wire clock,reset_n,frame_start_i,render_active_i,source_ready_i,live_selected_i,
    input wire [10:0] total_rows_i,committed_rows_i,
    input wire [1:0] mode_i,
    input wire native_i,certified_i,progress_i,
    output wire admit_o,
    output reg budget_exceeded_o,
    output wire live_fault_o
);
    wire [10:0] remaining=total_rows_i-committed_rows_i;
    wire compare_mode=mode_i==2;
    wire [10:0] last_scan_line=compare_mode ? 11'd539 : total_rows_i-1'b1;
    wire [10:0] first_scan_line=compare_mode ? 11'd180+(native_i ? committed_rows_i : (committed_rows_i>>1)) : committed_rows_i;
    wire [31:0] remaining_bound=remaining*MAX_ROW_CYCLES;
    wire [31:0] last_deadline=last_scan_line*SCAN_LINE_CYCLES;
    wire [31:0] first_deadline=first_scan_line*SCAN_LINE_CYCLES;
    wire [31:0] first_bound=(compare_mode&&!native_i ? 2 : 1)*MAX_ROW_CYCLES;
    wire tail_safe=remaining_bound+FETCH_MARGIN_CYCLES<=last_deadline;
    wire first_safe=first_bound+FETCH_MARGIN_CYCLES<=first_deadline;
    wire complete_image=total_rows_i!=0&&committed_rows_i==total_rows_i;
    // Two short metadata stages cut mode/index -> constant multiply ->
    // compare -> bank allocator. Row progress is monotonic within a locked
    // frame, so delayed positive eligibility remains conservative.
    reg [31:0] tail_bound_q,last_deadline_q,first_deadline_q,first_bound_q;
    reg qualified_q,complete_q,admit_q;
    always @(posedge clock)begin
        if(!reset_n||frame_start_i)begin qualified_q<=0;complete_q<=0;admit_q<=0;end
        else if(render_active_i)begin
            tail_bound_q<=remaining_bound+FETCH_MARGIN_CYCLES;
            last_deadline_q<=last_deadline;first_deadline_q<=first_deadline;
            first_bound_q<=first_bound+FETCH_MARGIN_CYCLES;
            complete_q<=complete_image;
            qualified_q<=source_ready_i&&(complete_image||(certified_i&&!budget_exceeded_o&&committed_rows_i>=8));
            admit_q<=qualified_q&&(complete_q||(tail_bound_q<=last_deadline_q&&first_bound_q<=first_deadline_q));
        end else begin qualified_q<=0;complete_q<=0;admit_q<=0;end
    end
    assign admit_o=admit_q&&render_active_i&&source_ready_i&&!frame_start_i&&
                   (certified_i||complete_q)&&(!budget_exceeded_o||complete_q);
    assign live_fault_o=live_selected_i&&budget_exceeded_o;
    reg [31:0] progress_gap;
    always @(posedge clock)begin
        if(!reset_n||frame_start_i)begin progress_gap<=0;budget_exceeded_o<=0;end
        else if(!render_active_i||!source_ready_i||complete_image||progress_i)progress_gap<=0;
        else begin
            if(progress_gap<8*MAX_ROW_CYCLES+1)progress_gap<=progress_gap+1'b1;
            if(progress_gap>=8*MAX_ROW_CYCLES)budget_exceeded_o<=1;
        end
    end
endmodule
