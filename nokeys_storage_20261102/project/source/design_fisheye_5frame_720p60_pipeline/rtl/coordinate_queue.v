`timescale 1ns/1ps
// 128 synchronous-RAM words plus two head registers. No asynchronous RAM read.
module coordinate_queue (
    input wire clock,reset_n,flush_i,
    input wire input_valid_i,
    input wire [49:0] input_data_i,
    output wire input_ready_o,
    output wire output_valid_o,
    output wire [49:0] output_data_o,
    input wire output_ready_i,
    output reg error_o
);
    reg [49:0] words [0:127] /* synthesis syn_ramstyle = "block_ram" */;
    reg [6:0] write_pointer,read_pointer;
    reg [7:0] ram_count;
    reg [49:0] fetched_word,head_words [0:1];
    reg fetch_pending,head_read_pointer,head_write_pointer;
    reg [1:0] head_count;
    assign input_ready_o = ram_count < 128;
    assign output_valid_o = head_count != 0;
    assign output_data_o = head_words[head_read_pointer];
    wire push = input_valid_i && input_ready_o;
    wire pop = output_valid_o && output_ready_i;
    wire [2:0] head_reserved = {1'b0,head_count}+{2'd0,fetch_pending};
    wire fetch = ram_count!=0 && (head_reserved<2 || pop);
    always @(posedge clock) begin
        if(!reset_n || flush_i) begin
            write_pointer<=0;read_pointer<=0;ram_count<=0;
            fetch_pending<=0;head_count<=0;head_read_pointer<=0;head_write_pointer<=0;error_o<=0;
        end else begin
            if(input_valid_i && !input_ready_o) error_o<=1;
            if(push) begin words[write_pointer]<=input_data_i;write_pointer<=write_pointer+1'b1;end
            if(fetch) begin fetched_word<=words[read_pointer];read_pointer<=read_pointer+1'b1;end
            fetch_pending<=fetch;
            case({push,fetch})
                2'b10:ram_count<=ram_count+1'b1;
                2'b01:ram_count<=ram_count-1'b1;
                default:ram_count<=ram_count;
            endcase
            if(fetch_pending) begin head_words[head_write_pointer]<=fetched_word;head_write_pointer<=~head_write_pointer;end
            if(pop) head_read_pointer<=~head_read_pointer;
            case({fetch_pending,pop})
                2'b10:head_count<=head_count+1'b1;
                2'b01:head_count<=head_count-1'b1;
                default:head_count<=head_count;
            endcase
        end
    end
endmodule
