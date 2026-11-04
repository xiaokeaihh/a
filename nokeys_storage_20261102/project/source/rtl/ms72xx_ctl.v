`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Myminieye
// Engineer: Nill
// 
// Create Date: 2019-09-16 19:46
// Design Name: 
// Module Name: ms7210_ctl
// Project Name: hdmi_tx
// Target Devices: Pg2l100H  
// Tool Versions: 
// Description:  
// 
// Dependencies: 
// Revision: v1.0
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`define UD #1
module ms72xx_ctl #(parameter integer ENABLE_RX=0, parameter integer RX_STALL_CYCLES=10000000)(
    input       clk,
    input       rst_n,
    input       rx_selected_i,
    input       rx_present_i,
    input       rx_retry_toggle_i,
    output [15:0] rx_recovery_status_o,
    
    output      init_over_rx,
    output      init_over,
    output      iic_scl,
    inout       iic_sda
);
    reg rstn_temp1,rstn_temp2;
    reg rstn;
    always @(posedge clk or negedge rst_n)
    begin
    	if(!rst_n)
    	    rstn_temp1 <= 1'b0;
    	else
    	    rstn_temp1 <= rst_n;
    end
    
    always @(posedge clk)
    begin
    	rstn_temp2 <= rstn_temp1;
    	rstn <= rstn_temp2;
    end
    
wire rx_init_complete;
assign init_over_rx=ENABLE_RX ? rx_init_complete : 1'b1;
    wire   [7:0] device_id_rx;
    wire         iic_trig_rx ;
    wire         w_r_rx      ;
    wire  [15:0] addr_rx     ;
    wire  [ 7:0] data_in_rx  ;
    wire         busy_rx     ;
    wire  [ 7:0] data_out_rx ;
    wire         byte_over_rx;
    
    wire   [7:0] device_id_tx;
    wire         iic_trig_tx ;
    wire         w_r_tx      ;
    wire  [15:0] addr_tx     ;
    wire  [ 7:0] data_in_tx  ;
    wire         busy_tx     ;
    wire  [ 7:0] data_out_tx ;
    wire         byte_over_tx;
    
    wire   [7:0] device_id   ;
    wire         iic_trig    ;
    wire         w_r         ;
    wire  [15:0] addr        /*synthesis PAP_MARK_DEBUG="true"*/;
    wire  [ 7:0] data_in     ;
    wire         busy        ;
    wire  [ 7:0] data_out    /*synthesis PAP_MARK_DEBUG="true"*/;
    wire         byte_over   /*synthesis PAP_MARK_DEBUG="true"*/;

    reg rx_bus_active;
    reg [5:0] handover_idle;
    wire rx_link_locked,rx_recovery_reset,rx_suppress_requests;
    // Control inputs come from the independent system clock. The guard runs
    // even if the external video clock stops completely.
    reg [2:0] selected_sync,present_sync,retry_sync;
    always @(posedge clk) begin
        if(!rstn) begin selected_sync<=0;present_sync<=0;retry_sync<=0;end
        else begin
            selected_sync<={selected_sync[1:0],rx_selected_i};
            present_sync<={present_sync[1:0],rx_present_i};
            retry_sync<={retry_sync[1:0],rx_retry_toggle_i};
        end
    end
    hdmi_rx_recovery_guard #(.STALL_CYCLES(RX_STALL_CYCLES)) u_rx_guard(
        .clk(clk),.reset_n(rstn),.bus_active_i(rx_bus_active),
        .selected_i(selected_sync[2]),.present_i(present_sync[2]),
        .retry_toggle_i(retry_sync[2]),.initialized_i(rx_init_complete),
        .link_locked_i(rx_link_locked),.busy_i(busy),.trigger_i(iic_trig_rx),
        .suppress_o(rx_suppress_requests),.reset_o(rx_recovery_reset),
        .status_o(rx_recovery_status_o));

    ms7200_ctl U1_ms7200_ctl(
        .clk             (  clk        ),//input               
        .rstn            (  rstn && rx_bus_active && !rx_recovery_reset ),//input
                              
        .init_over       (  rx_init_complete ),
        .link_locked_o   (  rx_link_locked ),//output reg          
        .device_id       (                ),//output        [7:0] 
        .iic_trig        (  iic_trig_rx   ),//output reg          
        .w_r             (  w_r_rx        ),//output reg          
        .addr            (  addr_rx       ),//output reg   [15:0] 
        .data_in         (  data_in_rx    ),//output reg   [ 7:0] 
        .busy            (  busy_rx       ),//input               
        .data_out        (  data_out_rx   ),//input        [ 7:0] 
        .byte_over       (  byte_over_rx  ) //input               
    );
    
    ms7210_ctl U2_ms7210_ctl(
        .clk             (  clk           ),//input               
        .rstn            (  rstn ),//input
                              
        .init_over       (  init_over     ),//output reg          
        .device_id       (                ),//output        [7:0] 
        .iic_trig        (  iic_trig_tx   ),//output reg          
        .w_r             (  w_r_tx        ),//output reg          
        .addr            (  addr_tx       ),//output reg   [15:0] 
        .data_in         (  data_in_tx    ),//output reg   [ 7:0] 
        .busy            (  busy_tx       ),//input               
        .data_out        (  data_out_tx   ),//input        [ 7:0] 
        .byte_over       (  byte_over_tx  ) //input               
    );
    
    // Camera output must start even when HDMI IN is unplugged. The receiver's
    // init_over waits for a live input clock, so it must never hold TX in reset.
    // Configure TX first, then give RX the shared bus for init and hotplug polls.
    always @(posedge clk) begin
        if (!rstn) begin
            rx_bus_active <= 1'b0;
            handover_idle <= 6'd0;
        end else if (!rx_bus_active && ENABLE_RX) begin
            // iic_dri pipelines pluse before raising busy. Drain both a queued
            // trigger and its transaction before changing any bus parameters.
            if (!init_over || busy || iic_trig_tx)
                handover_idle <= 6'd0;
            else if (handover_idle == 6'd63)
                rx_bus_active <= 1'b1;
            else
                handover_idle <= handover_idle + 1'b1;
        end
    end
    assign device_id = rx_bus_active ? 8'h56 : 8'hB2;
    assign iic_trig = rx_bus_active ? (iic_trig_rx && !rx_suppress_requests) : (iic_trig_tx && !init_over);
    assign w_r = rx_bus_active ? w_r_rx : w_r_tx;
    assign addr = rx_bus_active ? addr_rx : addr_tx;
    assign data_in = rx_bus_active ? data_in_rx : data_in_tx;
    assign busy_tx = rx_bus_active ? 1'b0 : busy;
    assign data_out_tx = rx_bus_active ? 8'd0 : data_out;
    assign byte_over_tx = rx_bus_active ? 1'b0 : byte_over;

    assign busy_rx = rx_bus_active ? busy : 1'b0;
    assign data_out_rx = rx_bus_active ? data_out : 8'd0;
    assign byte_over_rx = rx_bus_active ? byte_over : 1'b0;

    wire         sda_in/*synthesis PAP_MARK_DEBUG="true"*/;
    wire         sda_out/*synthesis PAP_MARK_DEBUG="true"*/;
    wire         sda_out_en/*synthesis PAP_MARK_DEBUG="true"*/;  
    iic_dri #(
        .CLK_FRE        (  27'd10_000_000  ),//parameter            CLK_FRE   = 27'd50_000_000,//system clock frequency
        .IIC_FREQ       (  20'd400_000     ),//parameter            IIC_FREQ  = 20'd400_000,   //I2c clock frequency
        .T_WR           (  10'd1           ),//parameter            T_WR      = 10'd5,         //I2c transmit delay ms
        .ADDR_BYTE      (  2'd2            ),//parameter            ADDR_BYTE = 2'd1,          //I2C addr byte number
        .LEN_WIDTH      (  8'd3            ),//parameter            LEN_WIDTH = 8'd3,          //I2C transmit byte width
        .DATA_BYTE      (  2'd1            ) //parameter            DATA_BYTE = 2'd1           //I2C data byte number
    )iic_dri(                       
        .clk            (  clk             ),//input                clk,
        .rstn           (  rstn && !(rx_bus_active && rx_recovery_reset) ),//input                rstn,
        .device_id      (  device_id       ),//input                device_id,
        .pluse          (  iic_trig        ),//input                pluse,                     //I2C transmit trigger
        .w_r            (  w_r             ),//input                w_r,                       //I2C transmit direction 1:send  0:receive
        .byte_len       (  4'd1            ),//input  [LEN_WIDTH:0] byte_len,                  //I2C transmit data byte length of once trigger
                   
        .addr           (  addr            ),//input  [7:0]         addr,                      //I2C transmit addr
        .data_in        (  data_in         ),//input  [7:0]         data_in,                   //I2C send data
                     
        .busy           (  busy            ),//output reg           busy=0,                    //I2C bus status
        
        .byte_over      (  byte_over       ),//output reg           byte_over=0,               //I2C byte transmit over flag               
        .data_out       (  data_out        ),//output reg[7:0]      data_out,                  //I2C receive data
                                           
        .scl            (  iic_scl         ),//output               scl,
        .sda_in         (  sda_in          ),//input                sda_in,
        .sda_out        (  sda_out         ),//output   reg         sda_out=1'b1,
        .sda_out_en     (  sda_out_en      ) //output               sda_out_en
    );
    
    assign iic_sda = sda_out_en ? sda_out : 1'bz;
    assign sda_in = iic_sda;
    
endmodule

// Independent observation of the physical FPGA input pins. This monitor is
// deliberately not gated by RX initialization or by format qualification.
module hdmi_input_activity #(parameter integer WINDOW_CYCLES=1000000)(
    input sys_clk,input reset_n,input pixel_clk,input vs_i,input de_i,
    output [4:0] activity_o
);
    reg [7:0] pixel_count;
    always @(posedge pixel_clk or negedge reset_n)
        if(!reset_n)pixel_count<=0;else pixel_count<=pixel_count+1'b1;
    reg [2:0] clock_sync,vs_sync,de_sync;
    reg [19:0] window_count;
    reg [2:0] seen,recent;
    wire [2:0] edges={de_sync[1]&&!de_sync[2],vs_sync[1]&&!vs_sync[2],clock_sync[1]^clock_sync[2]};
    always @(posedge sys_clk or negedge reset_n)begin
        if(!reset_n)begin
            clock_sync<=0;vs_sync<=0;de_sync<=0;window_count<=0;seen<=0;recent<=0;
        end else begin
            clock_sync<={clock_sync[1:0],pixel_count[7]};
            vs_sync<={vs_sync[1:0],vs_i};de_sync<={de_sync[1:0],de_i};
            if(window_count==WINDOW_CYCLES-1)begin
                recent<=seen|edges;seen<=0;window_count<=0;
            end else begin seen<=seen|edges;window_count<=window_count+1'b1;end
        end
    end
    assign activity_o={de_sync[2],vs_sync[2],(seen|recent)};
endmodule

// Re-run the existing receiver configuration only when its clock is locked
// but no frame reaches the FPGA. Never reset TX or change bus ownership.
module hdmi_rx_recovery_guard #(
    parameter integer STALL_CYCLES=10000000,
    parameter integer QUIET_CYCLES=64,
    parameter integer RESET_CYCLES=64
)(
    input clk,input reset_n,input bus_active_i,input selected_i,input present_i,
    input retry_toggle_i,input initialized_i,input link_locked_i,
    input busy_i,input trigger_i,
    output suppress_o,output reset_o,output [15:0] status_o
);
    localparam IDLE=2'd0,QUIET=2'd1,RESET=2'd2;
    reg [1:0] state,attempts;
    reg [23:0] stall_count;
    reg [7:0] quiet_count,reset_count,total;
    reg retry_previous,manual_pending;
    wire retry=retry_toggle_i!=retry_previous;
    assign suppress_o=state!=IDLE;
    assign reset_o=state==RESET;
    assign status_o={total,attempts,(attempts==2'd3),(state!=IDLE),
                     (state==RESET),link_locked_i,present_i,selected_i};
    always @(posedge clk) begin
        if(!reset_n) begin
            state<=IDLE;attempts<=0;stall_count<=0;quiet_count<=0;
            reset_count<=0;total<=0;retry_previous<=0;manual_pending<=0;
        end else begin
            retry_previous<=retry_toggle_i;
            if(!selected_i || present_i || retry) attempts<=0;
            // An explicit selection also gets one recovery if the receiver
            // is stuck before it can report clock lock or initialization.
            // Absent, unselected inputs never cause periodic resets.
            if(!selected_i || present_i)manual_pending<=0;
            else if(retry)manual_pending<=1;
            case(state)
                IDLE: begin
                    quiet_count<=0;reset_count<=0;
                    if(!bus_active_i || !selected_i || present_i || retry ||
                       (!manual_pending && (!initialized_i || !link_locked_i)) || attempts==2'd3)
                        stall_count<=0;
                    else if(stall_count==STALL_CYCLES-1) begin
                        stall_count<=0;state<=QUIET;
                    end else stall_count<=stall_count+1'b1;
                end
                QUIET: begin
                    // A trigger may be in iic_dri's pipeline before busy
                    // rises. Block new requests and drain 64 idle clocks.
                    if(!selected_i || present_i || !bus_active_i) begin
                        state<=IDLE;quiet_count<=0;
                    end else if(busy_i || trigger_i) quiet_count<=0;
                    else if(quiet_count==QUIET_CYCLES-1) begin
                        state<=RESET;reset_count<=0;
                        manual_pending<=0;
                        attempts<=attempts+1'b1;
                        if(total!=8'hff)total<=total+1'b1;
                    end else quiet_count<=quiet_count+1'b1;
                end
                RESET: begin
                    if(reset_count==RESET_CYCLES-1)begin
                        state<=IDLE;reset_count<=0;
                    end else reset_count<=reset_count+1'b1;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
