`timescale 1ns/1ps
// Eight retained requests double as a bounded miss queue. Cache queries keep
// running while the single owned DDR read waits. A validated 16x1 row repairs
// every matching request, including partial hits, without issuing duplicates.
module nonblocking_source_reader #(
 parameter integer REQUEST_BITS=3, SOURCE_CAPTURE_REVERSE=0
)(
 input wire source_reverse_i,
 input wire clock,reset_n,frame_start_i,output wire frame_accept_o,
 input wire [31:0] frame_id_i,input wire [1:0] source_bank_i,
 input wire abort_i,source_failed_i,source_complete_i,input wire [10:0] source_committed_i,
 input wire request_valid_i,request_inside_i,output wire request_ready_o,
 input wire [10:0] request_x_i,request_y_i,input wire [7:0] request_tag_i,
 output wire pixel_valid_o,input wire pixel_ready_i,output wire [63:0] pixels_o,
 output wire [7:0] pixel_tag_o,output wire busy_o,refill_active_o,output reg error_o,
 output reg [31:0] lookup_hits_o,lookup_misses_o,refill_count_o,
 output wire [4:0] activity_o,
 output wire lookup_valid_o,input wire lookup_ready_i,
 output wire [31:0] lookup_frame_o,output wire [1:0] lookup_bank_o,
 output wire [10:0] lookup_x_o,lookup_y_o,input wire response_valid_i,
 input wire [3:0] response_miss_i,input wire [63:0] response_pixels_i,
 output wire [27:0] axi_araddr,output wire [3:0] axi_arlen,output wire axi_arvalid,
 input wire axi_arready,input wire [255:0] axi_rdata,input wire axi_rvalid,axi_rlast,
 output wire fill_valid_o,input wire fill_ready_i,output wire [31:0] fill_frame_o,
 output wire [1:0] fill_bank_o,output wire [10:0] fill_x_o,fill_y_o,
 output wire [255:0] fill_pixels_o
);
    wire source_reverse = source_reverse_i === 1'b1 || (source_reverse_i !== 1'b0 && SOURCE_CAPTURE_REVERSE != 0);
 localparam N=1<<REQUEST_BITS;
 reg active,cancelled,room;reg [4:0] publication_guard;reg [31:0] frame;reg [1:0] bank;
 reg [REQUEST_BITS:0] count,pending;
 reg [REQUEST_BITS-1:0] head,tail,ph,pt,scan;
 reg [N-1:0] valid,returned;
 reg [REQUEST_BITS-1:0] pending_slot[0:N-1];
 reg [10:0] qx[0:N-1],qy[0:N-1];reg [7:0] tag[0:N-1];
 reg [3:0] acquired[0:N-1];reg [63:0] pixels[0:N-1];
 wire cancel=cancelled||abort_i||source_failed_i;
 wire refill_busy,refill_done,refill_error,response_wait,commit_wait,source_wait;
 assign busy_o=count!=0||pending!=0||refill_busy||(|publication_guard);
 assign frame_accept_o=reset_n&&frame_start_i&&!busy_o;
 // Neighbors are copied into retained slots before a tag can be replaced.
 // The pool drains all lookup tokens before either tap or refill commits.
 // Refill always has priority; no retry reads an evicted partial neighbor.
 assign refill_active_o=1'b0;
 // room is the exact registered count<N predicate, advanced on the SAME
 // push/pop edge. No interface cycle changes; remove the occupancy compare
 // from lookup/fill arbitration and its wide reset/enable fanout.
 assign request_ready_o=reset_n&&active&&!frame_start_i&&!cancel&&room&&
                         !fill_valid_o&&(!request_inside_i||lookup_ready_i);
 wire push=request_valid_i&&request_ready_o;
 assign lookup_valid_o=push&&request_inside_i;
 assign lookup_frame_o=frame;assign lookup_bank_o=bank;
 assign lookup_x_o=request_x_i;assign lookup_y_o=request_y_i;
 wire query=lookup_valid_o&&lookup_ready_i;
 wire response=response_valid_i&&pending!=0;
 wire [REQUEST_BITS-1:0] rs=pending_slot[ph];
 wire [1:0] origin={qy[rs][0],qx[rs][0]};
 assign pixel_valid_o=count!=0&&returned[head]&&(&acquired[head])&&!cancel;
 assign pixels_o=pixels[head];assign pixel_tag_o=tag[head];
 wire pop=pixel_valid_o&&pixel_ready_i;
 wire [3:0] missing=~acquired[scan];
 wire [1:0] first_missing=missing[0]?0:missing[1]?1:missing[2]?2:3;
 wire [10:0] repair_x=qx[scan]+first_missing[0];
 wire [10:0] repair_y=qy[scan]+first_missing[1];
 wire repair_safe=source_complete_i||(source_reverse ?
                       source_committed_i>=720-repair_y : source_committed_i>repair_y);
 wire start_refill=active&&!frame_start_i&&!cancel&&!refill_busy&&!refill_done&&
                    valid[scan]&&returned[scan]&&missing!=0&&repair_safe;
 wire forwarding=fill_valid_o&&fill_ready_i&&!cancel;
 assign activity_o={request_valid_i&&!request_ready_o&&!lookup_ready_i,
                    source_wait,refill_busy,response_wait,commit_wait};
 source_row_refill #(.SOURCE_CAPTURE_REVERSE(SOURCE_CAPTURE_REVERSE)) refill(
  .source_reverse_i(source_reverse_i),.clock(clock),.reset_n(reset_n),.start_i(start_refill),.abort_i(cancel),
  .frame_id_i(frame),.source_bank_i(bank),.source_x_i({repair_x[10:4],4'd0}),.source_y_i(repair_y),
  .source_committed_i(source_committed_i),.source_complete_i(source_complete_i),.source_failed_i(source_failed_i),
  .busy_o(refill_busy),.done_o(refill_done),.error_o(refill_error),
  .response_wait_o(response_wait),.commit_wait_o(commit_wait),.source_wait_o(source_wait),
  .axi_araddr(axi_araddr),.axi_arlen(axi_arlen),.axi_arvalid(axi_arvalid),.axi_arready(axi_arready),
  .axi_rdata(axi_rdata),.axi_rvalid(axi_rvalid),.axi_rlast(axi_rlast),
  .fill_valid_o(fill_valid_o),.fill_ready_i(fill_ready_i),.fill_frame_o(fill_frame_o),
  .fill_bank_o(fill_bank_o),.fill_x_o(fill_x_o),.fill_y_o(fill_y_o),.fill_pixels_o(fill_pixels_o));
 genvar s;
 generate for(s=0;s<N;s=s+1)begin: retained
  wire [10:0] right=qx[s]+11'd1,bottom=qy[s]+11'd1;
  wire [1:0] columns={fill_x_o[10:4]==right[10:4],fill_x_o[10:4]==qx[s][10:4]};
  wire [1:0] rows={fill_y_o==bottom,fill_y_o==qy[s]};
  wire [3:0] fm={rows[1]&&columns[1],rows[1]&&columns[0],rows[0]&&columns[1],rows[0]&&columns[0]};
  wire [3:0] rm={~response_miss_i[origin^2'd3],~response_miss_i[origin^2'd2],
                  ~response_miss_i[origin^2'd1],~response_miss_i[origin]};
  integer k;
  always @(posedge clock)begin
   if(!reset_n||frame_accept_o)begin
    qx[s]<=0;qy[s]<=0;tag[s]<=0;pixels[s]<=0;acquired[s]<=0;pending_slot[s]<=0;
   end else begin
    if(query&&pt==s)pending_slot[s]<=tail;
    if((response&&rs==s)||(forwarding&&valid[s]))
     acquired[s]<=acquired[s]|((response&&rs==s)?rm:4'd0)|((forwarding&&valid[s])?fm:4'd0);
    if(response&&rs==s)begin
     for(k=0;k<4;k=k+1)if(rm[k]&&!acquired[s][k])pixels[s][k*16+:16]<=response_pixels_i[k*16+:16];
    end
    // Cache accepts rows only after its lookup token pipeline drains.
    if(forwarding&&valid[s])begin
     for(k=0;k<4;k=k+1)if(fm[k]&&!acquired[s][k])
      pixels[s][k*16+:16]<=k[0]?fill_pixels_o[right[3:0]*16+:16]:fill_pixels_o[qx[s][3:0]*16+:16];
    end
    if(push&&tail==s)begin
     qx[s]<=request_x_i;qy[s]<=request_y_i;tag[s]<=request_tag_i;
     pixels[s]<=0;acquired[s]<=request_inside_i?0:4'hf;
    end
   end
  end
 end endgenerate
 always @(posedge clock)begin
  if(!reset_n||frame_accept_o)begin
   publication_guard<=0;room<=1;count<=0;pending<=0;head<=0;tail<=0;ph<=0;pt<=0;scan<=0;valid<=0;returned<=0;
   active<=reset_n;cancelled<=0;error_o<=0;frame<=frame_id_i;bank<=source_bank_i;
   lookup_hits_o<=0;lookup_misses_o<=0;refill_count_o<=0;
  end else begin
   publication_guard<=forwarding?5'b11111:{publication_guard[3:0],1'b0};
   scan<=scan+1'b1;
   if(start_refill)refill_count_o<=refill_count_o+1'b1;
   case({query,response})2'b10:pending<=pending+1'b1;2'b01:pending<=pending-1'b1;endcase
   if(query)pt<=pt+1'b1;
   if(response)begin
    ph<=ph+1'b1;returned[rs]<=1;
    if(response_miss_i==0)lookup_hits_o<=lookup_hits_o+1'b1;
    else lookup_misses_o<=lookup_misses_o+1'b1;
   end
   if(frame_start_i&&busy_o||response_valid_i&&pending==0||refill_done&&refill_error)begin
    error_o<=1;cancelled<=1;
   end
   if(cancel||refill_done&&refill_error)begin
    active<=0;cancelled<=1;if(source_failed_i)error_o<=1;
    if(pending==0&&!refill_busy)begin count<=0;head<=0;tail<=0;valid<=0;returned<=0;ph<=0;pt<=0;end
   end else begin
    case({push,pop})
     2'b10:begin count<=count+1'b1;room<=count<N-1;end
     2'b01:begin count<=count-1'b1;room<=1;end
    endcase
    if(pop)begin valid[head]<=0;returned[head]<=0;head<=head+1'b1;end
    if(push)begin
     valid[tail]<=1;returned[tail]<=!request_inside_i;tail<=tail+1'b1;
     if(request_inside_i&&(request_x_i>=1279||request_y_i>=719))begin error_o<=1;cancelled<=1;end
    end
   end
  end
 end
endmodule
