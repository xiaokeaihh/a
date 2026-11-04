`timescale 1ns/1ps
// Registered tournament: one compare level per edge, stable offer under stall.
module ready_task_scheduler #(parameter integer SLOT_BITS=2)(
 input wire clock,reset_n,cancel_i,
 input wire [(1<<SLOT_BITS)-1:0] task_valid_i,source_ready_i,output_space_i,
 input wire [(32<<SLOT_BITS)-1:0] deadlines_i,input wire [31:0] now_i,
 output reg grant_valid_o,input wire grant_ready_i,
 output reg [SLOT_BITS-1:0] grant_slot_o,output reg overdue_o
);
 localparam N=1<<SLOT_BITS,W=33+2*SLOT_BITS;
 reg [W-1:0] tree[1:2*N-1];reg [SLOT_BITS-1:0] cursor;reg [3:0] phase;
 wire accept=grant_valid_o&&grant_ready_i;
 wire [N-1:0] candidates=task_valid_i&source_ready_i&output_space_i;
 
 function [W-1:0] choose;
  input [W-1:0] a,b;
  begin
   choose=a[W-1]&&(!b[W-1]||(a[SLOT_BITS+:32]==b[SLOT_BITS+:32]?
     a[SLOT_BITS-1:0]<b[SLOT_BITS-1:0]:$signed(a[SLOT_BITS+:32]-b[SLOT_BITS+:32])<0))?a:b;
  end
 endfunction
 integer i;
 always @(posedge clock)begin
  if(!reset_n||cancel_i)begin
   grant_valid_o<=0;grant_slot_o<=0;overdue_o<=0;cursor<=0;phase<=0;
   for(i=1;i<2*N;i=i+1)tree[i]<=0;
  end else begin
   if(accept)cursor<=grant_slot_o+1'b1;
   if(grant_valid_o)begin
    if(grant_ready_i)grant_valid_o<=0;
   end else begin
    if(phase==0)begin
     begin
      for(i=0;i<N;i=i+1)tree[N+i]<={candidates[i],i[SLOT_BITS-1:0],deadlines_i[i*32+:32],(i[SLOT_BITS-1:0]-cursor)};
      phase<=1;
     end
    end else if(phase<=SLOT_BITS)begin
     for(i=1;i<N;i=i+1)if(i>=(N>>phase)&&i<(N>>(phase-1)))tree[i]<=choose(tree[2*i],tree[2*i+1]);
     phase<=phase+1'b1;
    end else begin
     phase<=0;
     if(tree[1][W-1]&&candidates[tree[1][32+SLOT_BITS+:SLOT_BITS]])begin
      grant_valid_o<=1;grant_slot_o<=tree[1][32+SLOT_BITS+:SLOT_BITS];
      overdue_o<=$signed(now_i-tree[1][SLOT_BITS+:32])>0;
     end
    end
   end
  end
 end
endmodule
