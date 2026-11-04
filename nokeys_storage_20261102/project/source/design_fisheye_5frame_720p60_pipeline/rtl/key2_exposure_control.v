`timescale 1ns/1ps
// KEY2 aliases the combined Gamma toggle. High exposure is a separate held
// override: changing Gamma never releases the fixed test exposure.
module key2_exposure_control #(parameter integer DEBOUNCE_CYCLES=540000)(
 input wire sys_clk,reset_n,key2,
 input wire remote_high_valid_i,remote_high_enable_i,
 output reg high_exposure_o,output reg gamma_toggle_o
);
 // Remote high-exposure override only; no physical Gamma toggle source.
 always @(posedge sys_clk or negedge reset_n)begin
  if(!reset_n)begin high_exposure_o<=0;gamma_toggle_o<=0;end
  else begin
   gamma_toggle_o<=0;
   if(remote_high_valid_i===1'b1)high_exposure_o<=remote_high_enable_i;
  end
 end
endmodule
