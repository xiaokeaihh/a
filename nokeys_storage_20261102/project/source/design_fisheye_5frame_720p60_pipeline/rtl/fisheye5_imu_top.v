`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:Meyesemi 
// Engineer: Will
// 
// Create Date: 2023-03-17  
// Design Name:  
// Module Name: 
// Project Name: 
// Target Devices: Pango
// Tool Versions: 
// Description: 
//      
// Dependencies: 
// 
// Revision:
// Revision 1.0 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`define UD #1
//cmos1銆乧mos2浜岄€変竴锛屼綔涓鸿棰戞簮杈撳叆
// Select exactly one camera as the DDR video input.
//`define CMOS_1
`define CMOS_2
module hdmi_ddr_ov5640_top#(
	parameter MEM_ROW_ADDR_WIDTH   = 15         ,
	parameter MEM_COL_ADDR_WIDTH   = 10         ,
	parameter MEM_BADDR_WIDTH      = 3          ,
	parameter MEM_DQ_WIDTH         =  32        ,
	parameter MEM_DQS_WIDTH        =  32/8,
    parameter integer HDMI_INPUT_ENABLE = 1,
    parameter integer SOURCE_CAPTURE_REVERSE = 1
)(
	input                                sys_clk              ,//27MHz board clock
    input                                clk_p ,
    input                                clk_n ,
//OV5640
    output  [1:0]                        cmos_init_done       ,//OV5640瀵勫瓨鍣ㄥ垵濮嬪寲瀹屾垚
    //coms1	
    inout                                cmos1_scl            ,//cmos1 i2c 
    inout                                cmos1_sda            ,//cmos1 i2c 
    input                                cmos1_vsync          ,//cmos1 vsync
    input                                cmos1_href           ,//cmos1 hsync refrence,data valid
    input                                cmos1_pclk           ,//cmos1 pxiel clock
    input   [7:0]                        cmos1_data           ,//cmos1 data
    output                               cmos1_reset          ,//cmos1 reset
    //coms2
    inout                                cmos2_scl            ,//cmos2 i2c 
    inout                                cmos2_sda            ,//cmos2 i2c 
    input                                cmos2_vsync          ,//cmos2 vsync
    input                                cmos2_href           ,//cmos2 hsync refrence,data valid
    input                                cmos2_pclk           ,//cmos2 pxiel clock
    input   [7:0]                        cmos2_data           ,//cmos2 data
    output                               cmos2_reset          ,//cmos2 reset
//DDR
    output                               mem_rst_n                 ,
    output                               mem_ck                    ,
    output                               mem_ck_n                  ,
    output                               mem_cke                   ,
    output                               mem_cs_n                  ,
    output                               mem_ras_n                 ,
    output                               mem_cas_n                 ,
    output                               mem_we_n                  ,
    output                               mem_odt                   ,
    output      [MEM_ROW_ADDR_WIDTH-1:0] mem_a                     ,
    output      [MEM_BADDR_WIDTH-1:0]    mem_ba                    ,
    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs                   ,
    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs_n                 ,
    inout       [MEM_DQ_WIDTH-1:0]       mem_dq                    ,
    output      [MEM_DQ_WIDTH/8-1:0]     mem_dm                    ,
    output reg                           heart_beat_led            ,
    output                               ddr_init_done             ,
// MS7200 RGB888 input from the board HDMI IN connector.
    input pixclk_in,vs_in,hs_in,de_in,
    input [7:0] r_in,g_in,b_in,
//MS72xx       
    output                               rstn_out                  ,
    output                               iic_tx_scl                ,
    inout                                iic_tx_sda                ,
    output                               hdmi_int_led              ,//HDMI_OUT鍒濆鍖栧畬鎴?//HDMI_OUT
    output                               pix_clk                   ,//pixclk                           
    output     wire                       vs_out                    , 
    output     wire                       hs_out                    , 
    output     wire                       de_out                    ,
    output     wire [7:0]                  r_out                     , 
    output     wire [7:0]                  g_out                     , 
    output     wire [7:0]                  b_out         ,
    // ICM-42688-P on FMC J3; UART goes to the baseboard CP2102 USB-C port.
    output                               imu_sclk      ,
    output                               imu_mosi      ,
    input                                imu_miso      ,
    output                               imu_cs_n      ,
    input                                imu_int1      ,
    input                                uart_rx,
    output                               uart_tx
);
/////////////////////////////////////////////////////////////////////////////////////
// ENABLE_DDR
    parameter CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH;//28
    parameter TH_1S = 27'd33000000;
/////////////////////////////////////////////////////////////////////////////////////
    reg  [15:0]                 rstn_1ms            ;
    wire                        cmos_scl            ;//cmos i2c clock
    wire                        cmos_sda            ;//cmos i2c data
    wire                        cmos_vsync          ;//cmos vsync
    wire                        cmos_href           ;//cmos hsync refrence,data valid
    wire                        cmos_pclk           ;//cmos pxiel clock
    wire   [7:0]                cmos_data           ;//cmos data
    wire                        cmos_reset          ;//cmos reset
    wire                        initial_en          ;
    wire[15:0]                  cmos1_d_16bit       ;
    wire                        cmos1_href_16bit    ;
    reg [7:0]                   cmos1_d_d0          ;
    reg                         cmos1_href_d0       ;
    reg                         cmos1_vsync_d0      ;
    wire                        cmos1_pclk_16bit    ;
    wire[15:0]                  cmos2_d_16bit       /*synthesis PAP_MARK_DEBUG="1"*/;
    wire                        cmos2_href_16bit    /*synthesis PAP_MARK_DEBUG="1"*/;
    reg [7:0]                   cmos2_d_d0          /*synthesis PAP_MARK_DEBUG="1"*/;
    reg                         cmos2_href_d0       /*synthesis PAP_MARK_DEBUG="1"*/;
    reg                         cmos2_vsync_d0      /*synthesis PAP_MARK_DEBUG="1"*/;
    wire                        cmos2_pclk_16bit    /*synthesis PAP_MARK_DEBUG="1"*/;
    wire[15:0]                  o_rgb565            ;
    //==== 高阶任务三：自适应预处理（插入显示通路）====
    wire[15:0]                  rgb_enh             ;
    wire[15:0]                  rgb_enh_visible     ;
    wire                        image_content_de    ;
    reg [8:0]                   content_pipe        ;
    wire                        gamma_enable        ;
    wire sharpen_enable = 1'b0; // Reserved telemetry/legacy OSD port only.
    wire remote_control_valid;wire [7:0] remote_control_code,remote_control_seq;
    wire gamma_requested;wire sharpen_requested=1'b0;wire [47:0] attitude_data;wire attitude_toggle;
    wire [1:0] ae_applied,ae_busy,ae_error,high_applied,awb_applied,awb_busy,awb_error;
    reg awb_requested;wire key2_gamma_toggle;
    wire high_exposure_requested;
`ifdef CMOS_1
    wire ae_applied_active=ae_applied[0],ae_busy_active=ae_busy[0],ae_error_active=ae_error[0],high_applied_active=high_applied[0],awb_applied_active=awb_applied[0]&&cmos_init_done[0],awb_busy_active=awb_busy[0],awb_error_active=awb_error[0];
`else
    wire ae_applied_active=ae_applied[1],ae_busy_active=ae_busy[1],ae_error_active=ae_error[1],high_applied_active=high_applied[1],awb_applied_active=awb_applied[1]&&cmos_init_done[1],awb_busy_active=awb_busy[1],awb_error_active=awb_error[1];
`endif
    wire hdmi_input_locked,hdmi_receiver_ready,hdmi_source_present;
    reg input_requested_hdmi,panorama_marker_requested,hdmi_retry_toggle;
    wire input_active_hdmi,input_switch_busy,input_stream_present,input_stream_error;
    wire selector_switch_busy;
    // Do not accept the frontend's reset VS level as a real HDMI SOF.
    // Keep camera pixels flowing until two complete 720p frames qualify RX.
    wire hdmi_qualified=hdmi_receiver_ready&&hdmi_source_present&&hdmi_input_locked;
    wire selector_requested_hdmi=input_requested_hdmi&&hdmi_qualified;
    assign input_switch_busy=selector_switch_busy||(input_requested_hdmi&&!hdmi_qualified);
    wire [15:0] rx_recovery_status;
    reg [15:0] rx_recovery_meta,rx_recovery_sync;
    wire [4:0] hdmi_pin_activity;
    wire [7:0] hdmi_activity={hdmi_source_present,hdmi_receiver_ready,hdmi_qualified,hdmi_pin_activity};
    reg [7:0] hdmi_activity_meta,hdmi_activity_sync;
    hdmi_input_activity u_hdmi_pin_monitor(.sys_clk(sys_clk),.reset_n(locked),
      .pixel_clk(hdmi_capture_clk),.vs_i(vs_in),.de_i(de_in),.activity_o(hdmi_pin_activity));
    wire capture_drained,capture_abort;
    reg [7:0] source_status_meta,source_status_sync;
    always @(posedge sys_clk or negedge locked)begin
      if(!locked)begin hdmi_retry_toggle<=0;input_requested_hdmi<=0;panorama_marker_requested<=0;source_status_meta<=0;source_status_sync<=0;end
      else begin
        if(remote_control_valid&&(remote_control_code==8'h96||remote_control_code==8'h97))input_requested_hdmi<=remote_control_code[0];
        if(remote_control_valid&&remote_control_code==8'h97)hdmi_retry_toggle<=~hdmi_retry_toggle;
        if(remote_control_valid&&(remote_control_code==8'h98||remote_control_code==8'h99))panorama_marker_requested<=remote_control_code[0];
        source_status_meta<={input_stream_error,panorama_marker_requested,input_requested_hdmi,input_switch_busy,
            input_stream_present,hdmi_receiver_ready,hdmi_input_locked,input_active_hdmi};
        source_status_sync<=source_status_meta;
      end
    end
    wire [4:0] image_requested={(!input_active_hdmi&&awb_requested),(!input_active_hdmi&&high_exposure_requested),sharpen_requested,(!input_active_hdmi&&auto_exposure_requested&&!high_exposure_requested),gamma_requested};
    wire [4:0] image_applied={(!input_active_hdmi&&awb_applied_active),(!input_active_hdmi&&high_applied_active),sharpen_enable,(!input_active_hdmi&&ae_applied_active),gamma_enable};
    wire image_busy=!input_active_hdmi&&(ae_busy_active||awb_busy_active);
    wire image_error=!input_active_hdmi&&(ae_error_active||awb_error_active);
    wire [7:0] image_capabilities=input_active_hdmi?8'h8b:8'hfb;
    wire [7:0] image_source_status=source_status_sync;
    reg [13:0] controls_meta,controls_sync;
    wire [63:0] controls_data={image_source_status,image_capabilities,remote_control_seq,7'd0,controls_sync[13],7'd0,controls_sync[12],3'd0,controls_sync[11:7],3'd0,controls_sync[6:2],8'd6};
    always @(posedge sys_clk or negedge locked)begin
      if(!locked)begin controls_meta<=0;controls_sync<=0;end
      else begin controls_meta<={image_error,image_busy,image_applied,image_requested,2'd0};controls_sync<=controls_meta;end
    end
    wire vs_sharp,hs_sharp,de_sharp,content_sharp;
    wire [15:0] rgb_sharp;
    wire [11:0]                 output_refresh_tenths;
    wire                        output_refresh_valid;
    wire                        de_enh              ;
    wire[2:0]                   enh_mode            ;
    wire[7:0]                   enh_mean            ;
    wire[7:0]                   enh_bright          ;
    wire[7:0]                   enh_dark            ;
    wire[7:0]                   enh_p10             ;
    wire[7:0]                   enh_p90             ;
    reg                         vs_o_d1, vs_o_d2, vs_o_d3, vs_o_d4, vs_o_d5, vs_o_d6, vs_o_d7, vs_o_d8, vs_o_d9;
    reg                         hs_o_d1, hs_o_d2, hs_o_d3, hs_o_d4, hs_o_d5, hs_o_d6, hs_o_d7, hs_o_d8, hs_o_d9;
    wire[15:0]                  osd_rgb565          ;
    wire[13:0]                  latency_tenth_ms    ;
    wire                        latency_valid       ;
    wire [55:0] pane_first_tenths,pane_end_tenths;
    wire [3:0] pane_first_valid,pane_end_valid;
    wire [6:0] pane_layout;
    reg measure_content_out;
    wire[13:0]                  capture_tenth_ms    ;
    wire[13:0]                  queue_tenth_ms      ;
    wire[13:0]                  render_tenth_ms     ;
    wire[13:0]                  display_tenth_ms    ;
    wire[7:0]                   corrected_fps       ;
    wire[11:0]                  camera_fps_tenths   ;
    wire                        camera_rate_valid  ;
    wire[7:0]                   raw_fps             ;
    wire[7:0]                   render_fps          ;
    wire                        hs_o                ;
    reg                         pixel_ready_meta = 1'b0;
    reg                         pixel_ready_sync = 1'b0;
    wire                        pclk_in_test        ;    
    wire                        vs_in_test          ;
    wire                        de_in_test          ;
    wire[15:0]                  camera_rgb565;
    wire[15:0]                  i_rgb565   /*synthesis PAP_MARK_DEBUG="1"*/         ;
    wire                        de_re               ;
//axi bus   
    wire [CTRL_ADDR_WIDTH-1:0]  axi_awaddr                 ;
    wire                        axi_awuser_ap              ;
    wire [3:0]                  axi_awuser_id              ;
    wire [3:0]                  axi_awlen                  ;
    wire                        axi_awready                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire                        axi_awvalid                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [MEM_DQ_WIDTH*8-1:0]   axi_wdata                  ;
    wire [MEM_DQ_WIDTH*8/8-1:0] axi_wstrb                  ;
    wire                        axi_wready                 ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [3:0]                  axi_wusero_id              ;
    wire                        axi_wusero_last            ;
    wire [CTRL_ADDR_WIDTH-1:0]  axi_araddr                 ;
    wire                        axi_aruser_ap              ;
    wire [3:0]                  axi_aruser_id              ;
    wire [3:0]                  axi_arlen                  ;
    wire                        axi_arready                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire                        axi_arvalid                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [MEM_DQ_WIDTH*8-1:0]   axi_rdata                   /* synthesis syn_keep = 1 */;
    wire                        axi_rvalid                  /* synthesis syn_keep = 1 */;
    wire [3:0]                  axi_rid                    ;
    wire                        axi_rlast                  ;
    reg  [26:0]                 cnt                        ;
    reg  [15:0]                 cnt_1                      ;
/////////////////////////////////////////////////////////////////////////////////////
//PLL

    wire hdmi_capture_clk;
    GTP_CLKBUFG u_hdmi_rx_clock_buffer(.CLKIN(pixclk_in),.CLKOUT(hdmi_capture_clk));
    wire local_pix_clk,output_clock_reset_n,output_follows_hdmi;
    wire raster_enable,raster_frame_end,phase_locked,certified_base_active;
    wire [1:0] raster_phase_adjust;
    wire [2:0] phase_state;
    wire [7:0] admission_ddr_status;
    reg [7:0] admission_status_meta,admission_status_sync;
    wire [20:0] phase_target;wire [23:0] phase_worst,ready_cycles;
    wire ready_toggle;wire [15:0] clock_switches,phase_acquisitions;
    wire [20:0] last_ready_phase,last_output_phase;
    wire [223:0] output_sync_status;
    reg raster_end_toggle;
    wire low_latency_requested;
    pll u_pll (
        .clkin1   (  sys_clk    ),//27MHz
        .clkout0  (  local_pix_clk    ),//74.25 MHz, 720p60 with 1650x750 total timing
        .clkout1  (  cfg_clk    ),//10MHz
        .clkout2  (  clk_25M    ),//25M
        .lock (  locked     )
    );

    // Board keys removed. Keep the existing default HDMI clock-follow mode.
    assign low_latency_requested=1'b1;
    always @(posedge pix_clk or negedge output_clock_reset_n)
      if(!output_clock_reset_n)raster_end_toggle<=0;
      else if(raster_frame_end)raster_end_toggle<=~raster_end_toggle;
    hdmi_output_clock u_output_clock(
      .sys_clk(sys_clk),.reset_n(locked),.local_pixel_clk(local_pix_clk),
      .rx_pixel_clk(hdmi_capture_clk),.rx_vsync(hdmi_front_vs),
      .source_enabled_i(input_active_hdmi&&!input_switch_busy&&hdmi_input_locked&&hdmi_source_present),
      .requested_i(low_latency_requested),.frame_end_toggle_i(raster_end_toggle),
      .pixel_clk_o(pix_clk),.pixel_reset_n_o(output_clock_reset_n),
      .following_o(output_follows_hdmi),.switches_o(clock_switches));
    hdmi_frame_phase u_output_phase(
      .pixel_clk(pix_clk),.reset_n(output_clock_reset_n&&ddr_init_done),
      .following_i(output_follows_hdmi),.source_vs_i(hdmi_front_vs),
      .fast_profile_i(!admission_status_sync[4]),
      .certified_base_i(selected_display_mode==2'd3&&render_view==3'd7&&!stabilization_enable),
      .frame_end_i(raster_frame_end),.raster_vs_i(vs_o),.epoch_i({selected_display_mode,render_view}),
      .ready_toggle_i(ready_toggle),.ready_cycles_i(ready_cycles),
      .raster_enable_o(raster_enable),.locked_o(phase_locked),
      .target_phase_o(phase_target),.worst_ready_cycles_o(phase_worst),.acquisitions_o(phase_acquisitions),
      .last_ready_phase_o(last_ready_phase),.last_output_phase_o(last_output_phase),
      .state_o(phase_state),.certified_base_active_o(certified_base_active),.phase_adjust_o(raster_phase_adjust));

    reg [3:0] sync_flags_meta,sync_flags;reg sync_vs_previous;
    wire [20:0] hdmi_stability_ddr,hdmi_stability_pixel;
    wire hdmi_stability_valid;
    pipeline_diagnostics_cdc #(.DATA_WIDTH(21)) u_hdmi_stability_cdc(
      .source_clock(core_clk),.source_reset_n(ddr_init_done),
      .source_valid_i(hdmi_stability_valid),.source_data_i(hdmi_stability_ddr),
      .destination_clock(pix_clk),.destination_reset_n(output_clock_reset_n),
      .destination_valid_o(),.destination_data_o(hdmi_stability_pixel));
    wire [223:0] sync_pixel_status={hdmi_stability_pixel[20:10],last_output_phase,certified_base_active,hdmi_stability_pixel[9:0],last_ready_phase,
      8'd0,hdmi_activity_sync,phase_acquisitions,rx_recovery_sync,clock_switches,8'd0,phase_worst,11'd0,phase_target,
      16'd5,admission_status_sync,phase_state,raster_enable,sync_flags[3],phase_locked,sync_flags[1:0]};
    always @(posedge pix_clk or negedge output_clock_reset_n)begin
      if(!output_clock_reset_n)begin hdmi_activity_meta<=0;hdmi_activity_sync<=0;rx_recovery_meta<=0;rx_recovery_sync<=0;sync_flags_meta<=0;sync_flags<=0;sync_vs_previous<=0;admission_status_meta<=0;admission_status_sync<=0;end
      else begin
        rx_recovery_meta<=rx_recovery_status;rx_recovery_sync<=rx_recovery_meta;
        hdmi_activity_meta<=hdmi_activity;hdmi_activity_sync<=hdmi_activity_meta;
        sync_flags_meta<={input_active_hdmi,1'b0,output_follows_hdmi,low_latency_requested};
        sync_flags<=sync_flags_meta;sync_vs_previous<=vs_o;
        admission_status_meta<=admission_ddr_status;admission_status_sync<=admission_status_meta;
      end
    end
    pipeline_diagnostics_cdc #(.DATA_WIDTH(224)) u_output_sync_status(
      .source_clock(pix_clk),.source_reset_n(output_clock_reset_n),
      .source_valid_i(vs_o&&!sync_vs_previous),.source_data_i(sync_pixel_status),
      .destination_clock(sys_clk),.destination_reset_n(locked&&output_clock_reset_n),
      .destination_valid_o(),.destination_data_o(output_sync_status));

    // Shared 10-us hardware time; camera VSYNC and IMU DRDY are tagged here.
    wire diagnostics_ddr_valid,diagnostics_sys_valid;
    wire [1279:0] diagnostics_ddr_data,diagnostics_sys_data;
    pipeline_diagnostics_cdc u_pipeline_diagnostics_cdc(.source_clock(core_clk),.source_reset_n(ddr_init_done),
      .source_valid_i(diagnostics_ddr_valid),.source_data_i(diagnostics_ddr_data),
      .destination_clock(sys_clk),.destination_reset_n(locked),.destination_valid_o(diagnostics_sys_valid),.destination_data_o(diagnostics_sys_data));
    reg [8:0] hardware_div;reg [31:0] hardware_tick;
    reg [31:0] hardware_gray;reg [2:0] camera_sync;
    reg [63:0] frame_data_sys;reg frame_toggle,frame_event;
    reg [31:0] next_frame;
    wire fast_uart,stabilization_enable,pose_valid,display_stabilized,shown_stabilized;
    wire [31:0] displayed_source_frame,displayed_source_tick;
    reg [1:0] stabilization_sync_sys;wire stabilization_enable_sys=stabilization_sync_sys[1];
    wire [31:0] pose_frame,pose_tick;wire [287:0] pose_matrix;wire [1439:0] pose_views;wire pose_allviews;wire [2:0] pose_view;wire [7:0] pose_sequence;wire pose_tagged;
    reg [63:0] frame_data_ddr;reg [2:0] frame_sync;
    reg [31:0] gray_meta,gray_sync;
    wire [31:0] tick_ddr;
    genvar tickbit;generate for(tickbit=0;tickbit<32;tickbit=tickbit+1)begin: decode_tick
      assign tick_ddr[tickbit]=^gray_sync[31:tickbit];
    end endgenerate
    always @(posedge sys_clk or negedge locked)begin
      if(!locked)begin hardware_div<=0;hardware_tick<=0;hardware_gray<=0;camera_sync<=0;frame_toggle<=0;frame_event<=0;frame_data_sys<=0;next_frame<=0;end
      else begin
        frame_event<=0;camera_sync<={camera_sync[1:0],vs_in_test};
        if(hardware_div==269)begin hardware_div<=0;hardware_tick<=hardware_tick+1'b1;hardware_gray<=((hardware_tick+1'b1)>>1)^(hardware_tick+1'b1);end
        else hardware_div<=hardware_div+1'b1;
        if(camera_sync[1]&&!camera_sync[2])begin
          frame_data_sys<={hardware_tick,next_frame};next_frame<=next_frame+1'b1;frame_toggle<=~frame_toggle;frame_event<=1;
        end
      end
    end
    always @(posedge core_clk)begin
      if(!ddr_init_done)begin frame_sync<=0;frame_data_ddr<=0;gray_meta<=0;gray_sync<=0;end
      else begin
        frame_sync<={frame_sync[1:0],frame_toggle};gray_meta<=hardware_gray;gray_sync<=gray_meta;
        if(frame_sync[2]!=frame_sync[1])frame_data_ddr<=frame_data_sys;
      end
    end
    icm42688_uart_bridge #(
        .CLK_HZ(27000000),
        .UART_BAUD(115200),
        .SPI_HALF_DIV(14)
    ) imu_uart_inst (
        .clk(sys_clk),
        .rst_n(locked),
        .shown_stabilized_i(shown_stabilized),.stabilization_enable_i(stabilization_enable_sys),
        .fast_uart_i(fast_uart),.hardware_tick_i(hardware_tick),.frame_event_i(frame_event),.frame_data_i(frame_data_sys),.diagnostics_i(diagnostics_sys_valid),.diagnostics_data_i(diagnostics_sys_data),
        .imu_miso(imu_miso),
        .imu_int1(imu_int1),
        .imu_sclk(imu_sclk),
        .imu_mosi(imu_mosi),
        .imu_cs_n(imu_cs_n),
        .shown_test(test_sync_sys),.shown_view(shown_view),.shown_seq(shown_seq),.shown_mode(shown_mode),.shown_valid(shown_valid),
        .controls_data_i(controls_data),.output_sync_capable_i(1'b1),.output_sync_data_i(output_sync_status),.uart_tx(uart_tx)
    );

//閰嶇疆7210
wire init_over_tx;
    ms72xx_ctl #(.ENABLE_RX(HDMI_INPUT_ENABLE)) ms72xx_ctl(
        .rx_selected_i(input_requested_hdmi),.rx_present_i(hdmi_source_present),
        .rx_retry_toggle_i(hdmi_retry_toggle),.rx_recovery_status_o(rx_recovery_status),
        .clk             (  cfg_clk        ), //input       clk,
        .rst_n           (  rstn_out       ), //input       rstn,
        .init_over    (  init_over_tx   ), //output      init_over,                                
        .init_over_rx    (  init_over_rx   ), //output      init_over,
//        .iic_tx_scl      (  iic_tx_scl     ), //output      iic_scl,
//        .iic_tx_sda      (  iic_tx_sda     ), //inout       iic_sda
        .iic_scl         (  iic_tx_scl        ), //output      iic_scl,
        .iic_sda         (  iic_tx_sda        )  //inout       iic_sda
    );
//   assign    hdmi_int_led    =    init_over_tx; 
    
    always @(posedge cfg_clk)
    begin
    	if(!locked)
    	    rstn_1ms <= 16'd0;
    	else
    	begin
    		if(rstn_1ms == 16'h2710)
    		    rstn_1ms <= rstn_1ms;
    		else
    		    rstn_1ms <= rstn_1ms + 1'b1;
    	end
    end
    
    assign rstn_out = (rstn_1ms == 16'h2710);

//閰嶇疆CMOS///////////////////////////////////////////////////////////////////////////////////
//OV5640 register configure enable    
    power_on_delay	power_on_delay_inst(
    	.clk_50M                 (sys_clk        ),//input
    	.reset_n                 (1'b1           ),//input	
    	.camera1_rstn            (cmos1_reset    ),//output
    	.camera2_rstn            (cmos2_reset    ),//output	
    	.camera_pwnd             (               ),//output
    	.initial_en              (initial_en     ) //output		
    );
    wire auto_exposure_requested=gamma_requested;
    key2_exposure_control u_key2_exposure_control (
        .sys_clk(sys_clk), .reset_n(locked), .key2(1'b1),
        .remote_high_valid_i(remote_control_valid&&(remote_control_code==8'h8e||remote_control_code==8'h8f)),
        .remote_high_enable_i(remote_control_code[0]),.high_exposure_o(high_exposure_requested),
        .gamma_toggle_o(key2_gamma_toggle)
    );
    always @(posedge sys_clk or negedge locked)begin
        if(!locked)awb_requested<=1'b1;
        else if(remote_control_valid&&(remote_control_code==8'h94||remote_control_code==8'h95))awb_requested<=remote_control_code[0];
    end
    wire meter1_valid,meter1_fast,meter1_toggle;wire [1:0] meter1_direction;
    wire meter2_valid,meter2_fast,meter2_toggle;wire [1:0] meter2_direction;
`ifdef CMOS_1
    camera_exposure_meter u_meter1(
        .clk(cmos1_pclk_16bit),.reset_n(cmos1_reset),.vs(cmos1_vsync_d0),
        .de(cmos1_href_16bit),.rgb(cmos1_d_16bit),
        .valid_o(meter1_valid),.direction_o(meter1_direction),.fast_o(meter1_fast),.toggle_o(meter1_toggle));
    assign {meter2_valid,meter2_direction,meter2_fast,meter2_toggle}=5'd0;
`elsif CMOS_2
    camera_exposure_meter u_meter2(
        .clk(cmos2_pclk_16bit),.reset_n(cmos2_reset),.vs(cmos2_vsync_d0),
        .de(cmos2_href_16bit),.rgb(cmos2_d_16bit),
        .valid_o(meter2_valid),.direction_o(meter2_direction),.fast_o(meter2_fast),.toggle_o(meter2_toggle));
    assign {meter1_valid,meter1_direction,meter1_fast,meter1_toggle}=5'd0;
`endif
//CMOS1 Camera 
    reg_config #(.REVERSE_CAPTURE(SOURCE_CAPTURE_REVERSE)) coms1_reg_config(
    	.clk_25M                 (clk_25M            ),//input
    	.camera_rstn             (cmos1_reset        ),//input
        .auto_exposure_i        (auto_exposure_requested),
        .high_exposure_i        (high_exposure_requested),
        .auto_white_balance_i(awb_requested),
        .meter_valid_i(meter1_valid),.meter_direction_i(meter1_direction),
        .meter_fast_i(meter1_fast),.meter_toggle_i(meter1_toggle),
        .auto_white_balance_applied_o(awb_applied[0]),.auto_white_balance_busy_o(awb_busy[0]),.auto_white_balance_error_o(awb_error[0]),
        .high_exposure_applied_o(high_applied[0]),
        .auto_exposure_applied_o(ae_applied[0]), .auto_exposure_busy_o(ae_busy[0]), .auto_exposure_error_o(ae_error[0]),
    	.initial_en              (initial_en         ),//input		
    	.i2c_sclk                (cmos1_scl          ),//output
    	.i2c_sdat                (cmos1_sda          ),//inout
    	.reg_conf_done           (cmos_init_done[0]  ),//output config_finished
    	.reg_index               (                   ),//output reg [8:0]
    	.clock_20k               (                   ) //output reg
    );

//CMOS2 Camera 
    reg_config #(.REVERSE_CAPTURE(SOURCE_CAPTURE_REVERSE)) coms2_reg_config(
    	.clk_25M                 (clk_25M            ),//input
    	.camera_rstn             (cmos2_reset        ),//input
        .auto_exposure_i        (auto_exposure_requested),
        .high_exposure_i        (high_exposure_requested),
        .auto_white_balance_i(awb_requested),
        .meter_valid_i(meter2_valid),.meter_direction_i(meter2_direction),
        .meter_fast_i(meter2_fast),.meter_toggle_i(meter2_toggle),
        .auto_white_balance_applied_o(awb_applied[1]),.auto_white_balance_busy_o(awb_busy[1]),.auto_white_balance_error_o(awb_error[1]),
        .high_exposure_applied_o(high_applied[1]),
        .auto_exposure_applied_o(ae_applied[1]), .auto_exposure_busy_o(ae_busy[1]), .auto_exposure_error_o(ae_error[1]),
    	.initial_en              (initial_en         ),//input		
    	.i2c_sclk                (cmos2_scl          ),//output
    	.i2c_sdat                (cmos2_sda          ),//inout
    	.reg_conf_done           (cmos_init_done[1]  ),//output config_finished
    	.reg_index               (                   ),//output reg [8:0]
    	.clock_20k               (                   ) //output reg
    );
//CMOS 8bit杞?6bit///////////////////////////////////////////////////////////////////////////////////
//CMOS1
    wire camera1_ready_sync, camera2_ready_sync;
    camera_ready_synchronizer camera1_ready_cdc (
        .clock(cmos1_pclk), .level_i(cmos_init_done[0]), .level_o(camera1_ready_sync)
    );
    camera_ready_synchronizer camera2_ready_cdc (
        .clock(cmos2_pclk), .level_i(cmos_init_done[1]), .level_o(camera2_ready_sync)
    );
    always@(posedge cmos1_pclk)
        begin
            cmos1_d_d0        <= cmos1_data    ;
            cmos1_href_d0     <= cmos1_href    ;
            cmos1_vsync_d0    <= cmos1_vsync   ;
        end

    cmos_8_16bit cmos1_8_16bit(
    	.pclk           (cmos1_pclk       ),//input
    	.rst_n          (camera1_ready_sync),//input
    	.pdata_i        (cmos1_d_d0       ),//input[7:0]
    	.de_i           (cmos1_href_d0    ),//input
    	.vs_i           (cmos1_vsync_d0    ),//input
    	
    	.pixel_clk      (cmos1_pclk_16bit ),//output
    	.pdata_o        (cmos1_d_16bit    ),//output[15:0]
    	.de_o           (cmos1_href_16bit ) //output
    );
//CMOS2
    always@(posedge cmos2_pclk)
        begin
            cmos2_d_d0        <= cmos2_data    ;
            cmos2_href_d0     <= cmos2_href    ;
            cmos2_vsync_d0    <= cmos2_vsync   ;
        end

    cmos_8_16bit cmos2_8_16bit(
    	.pclk           (cmos2_pclk       ),//input
    	.rst_n          (camera2_ready_sync),//input
    	.pdata_i        (cmos2_d_d0       ),//input[7:0]
    	.de_i           (cmos2_href_d0    ),//input
    	.vs_i           (cmos2_vsync_d0    ),//input
    	
    	.pixel_clk      (cmos2_pclk_16bit ),//output
    	.pdata_o        (cmos2_d_16bit    ),//output[15:0]
    	.de_o           (cmos2_href_16bit ) //output
    );
//杈撳叆瑙嗛婧愰€夋嫨//////////////////////////////////////////////////////////////////////////////////////////
    wire hdmi_front_vs,hdmi_front_de,hdmi_sample_vs,hdmi_sample_de;wire [15:0] hdmi_front_rgb;
    hdmi_input_frontend u_hdmi_input(
      .sys_clk(sys_clk),.reset_n(locked),.receiver_ready_i(init_over_rx),
      .pixel_clk(hdmi_capture_clk),.vs_i(vs_in),.de_i(de_in),.r_i(r_in),.g_i(g_in),.b_i(b_in),
      .vs_o(hdmi_front_vs),.de_o(hdmi_front_de),.rgb_o(hdmi_front_rgb),
      .sample_vs_o(hdmi_sample_vs),.sample_de_o(hdmi_sample_de),
      .format_locked_o(hdmi_input_locked),.receiver_ready_o(hdmi_receiver_ready),.source_present_o(hdmi_source_present));
`ifdef CMOS_1
    wire camera_port_clk=cmos1_pclk_16bit,camera_port_vs=cmos1_vsync_d0,camera_port_de=cmos1_href_16bit;
    wire [15:0] camera_port_rgb=cmos1_d_16bit;
`else
    wire camera_port_clk=cmos2_pclk_16bit,camera_port_vs=cmos2_vsync_d0,camera_port_de=cmos2_href_16bit;
    wire [15:0] camera_port_rgb=cmos2_d_16bit;
`endif
    dual_video_input u_dual_input(.clock(core_clk),.reset_n(ddr_init_done),
      .requested_hdmi_i(selector_requested_hdmi),.capture_drained_i(capture_drained),.capture_abort_o(capture_abort),
      .camera_clk(camera_port_clk),.camera_vs(camera_port_vs),.camera_de(camera_port_de),.camera_rgb(camera_port_rgb),
      .hdmi_clk(hdmi_capture_clk),.hdmi_vs(hdmi_front_vs),.hdmi_de(hdmi_front_de),.hdmi_rgb(hdmi_front_rgb),
      .active_hdmi_o(input_active_hdmi),.switch_busy_o(selector_switch_busy),.present_o(input_stream_present),.error_o(input_stream_error),
      .vs_o(vs_in_test),.de_o(de_in_test),.rgb_o(camera_rgb565));
    assign pclk_in_test=core_clk;
    assign hdmi_int_led=input_stream_present;
//////////////////////////////////////////////////////////////////////////////////////////////////////////
//淇敼ddr璇诲啓妯″潡v1
    // Five DDR frame slots: three complete raw frames and two corrected frames.
    // The existing IMU SPI reader and UART transmitter above remain active.
    wire [2:0] requested_view,display_view,shown_view;
    wire [7:0] requested_seq,display_seq,shown_seq;
    wire [1:0] shown_mode;wire shown_valid;
    wire static_test_requested,static_test_camera;
    assign i_rgb565=camera_rgb565;
    reg test_meta_sys,test_sync_sys;
    always @(posedge sys_clk or negedge locked)begin
      if(!locked)begin test_meta_sys<=0;test_sync_sys<=0;end
      else begin test_meta_sys<=static_test_camera;test_sync_sys<=test_meta_sys;end
    end
    always @(posedge sys_clk)if(!locked)stabilization_sync_sys<=0;else stabilization_sync_sys<={stabilization_sync_sys[0],stabilization_enable};
    multiview_control u_multiview_control(
        .sys_clk(sys_clk),.sys_reset_n(locked),.uart_rx(uart_rx),
        .ddr_clk(core_clk),.ddr_reset_n(ddr_init_done),
        .control_valid_o(remote_control_valid),.control_code_o(remote_control_code),.control_seq_o(remote_control_seq),
        .attitude_data_o(attitude_data),.attitude_toggle_o(attitude_toggle),
        .fast_uart_o(fast_uart),.stabilization_enable_o(stabilization_enable),
        .pose_valid_o(pose_valid),.pose_frame_o(pose_frame),.pose_tick_o(pose_tick),.pose_matrix_o(pose_matrix),
        .pose_views_o(pose_views),.pose_allviews_o(pose_allviews),
        .pose_view_o(pose_view),.pose_sequence_o(pose_sequence),.pose_tagged_o(pose_tagged),
        .display_stabilized_i(display_stabilized),.shown_stabilized_o(shown_stabilized),
        .requested_view_o(requested_view),.requested_seq_o(requested_seq),.static_test_o(static_test_requested),
        .pixel_clk(pix_clk),.pixel_reset_n(pixel_ready_sync),.vsync(vs_o),.content_de(image_content_de),
        .display_view_i(display_view),.display_seq_i(display_seq),.display_mode_i(active_display_mode),
        .shown_view_o(shown_view),.shown_seq_o(shown_seq),.shown_mode_o(shown_mode),.shown_valid_o(shown_valid));
    wire [1:0] requested_display_mode;
    wire [2:0] comparison_view;
    reg [1:0] panorama_core;
    always @(posedge core_clk or negedge ddr_init_done)begin
      if(!ddr_init_done)panorama_core<=0;else panorama_core<={panorama_core[0],panorama_marker_requested};
    end
    wire [1:0] selected_display_mode=panorama_core[1]?2'd0:requested_display_mode;
    wire [2:0] render_view = selected_display_mode==2'd3 ? 3'd7 :
                             selected_display_mode==2'd1 ? 3'd5 : comparison_view;
    wire [1:0] active_display_mode;
    key0_mode_control u_key0_mode_control (
        .sys_clk(sys_clk), .sys_reset_n(locked), .key0(1'b1),
        .ddr_clk(core_clk), .ddr_reset_n(ddr_init_done),
        .view_seq_i(requested_seq),.requested_view_i(requested_view),.requested_mode_o(requested_display_mode),
        .comparison_view_o(comparison_view)
    );


    key1_gamma_control u_key1_gamma_control (
        .sys_clk(sys_clk), .sys_reset_n(locked), .key1(1'b1),
        .pixel_clk(pix_clk), .pixel_reset_n(pixel_ready_sync), .vsync(vs_o),
        .toggle_request_i(key2_gamma_toggle),
        .remote_valid_i(remote_control_valid&&(remote_control_code==8'h86||remote_control_code==8'h87||remote_control_code==8'h88||remote_control_code==8'h89)),.remote_enable_i(remote_control_code[0]),
        .requested_enable_o(gamma_requested),.enable_o(gamma_enable)
    );

    wire displayed_hdmi;
    fisheye_video_path #(.SOURCE_CAPTURE_REVERSE(SOURCE_CAPTURE_REVERSE),.MEASURE_OUTPUT_FEEDBACK(1)) u_fisheye_video_path(
        .source_reverse_i(!input_active_hdmi),.capture_abort_i(capture_abort),.capture_drained_o(capture_drained),
        .streaming_enabled_i(output_follows_hdmi),
        .certified_base_phase_i(certified_base_active),.phase_locked_i(phase_locked),
        .sync_ready_toggle_o(ready_toggle),.sync_ready_cycles_o(ready_cycles),
        .hdmi_admission_status_o(admission_ddr_status),
        .hdmi_stability_o(hdmi_stability_ddr),.hdmi_stability_valid_o(hdmi_stability_valid),
        .ddr_clk        (  core_clk             ),//input                         ddr_clk,
        .ddr_rstn       (  ddr_init_done        ),//input                         ddr_rstn,
        //data_in                                  
        .vin_clk        (  pclk_in_test         ),//input                         vin_clk,
        .wr_fsync       (  vs_in_test           ),//input                         wr_fsync,
        .wr_en          (  de_in_test           ),//input                         wr_en,
        .wr_data        (  i_rgb565             ),//input  [15 : 0]  wr_data,
        //data_out
        .vout_clk       (  pix_clk              ),//input                         vout_clk,
        .rd_fsync       (  vs_o               ),//input                         rd_fsync,
        .rd_en          (  de_re                ),//input                         rd_en,
        .vout_de        (  de_o               ),//output                        vout_de,
        .vout_content_de(image_content_de),
        .measure_vsync_i(vs_out),.measure_de_i(de_out),.measure_content_i(measure_content_out),
        .measure_enhanced_i(gamma_enable),
        .vout_data      (  o_rgb565             ),//output [PIX_WIDTH- 1'b1 : 0]  vout_data,
        .stabilization_enable_i(stabilization_enable&&!input_active_hdmi),.pose_valid_i(pose_valid),
        .pose_frame_i(pose_frame),.pose_tick_i(pose_tick),.pose_matrix_i(pose_matrix),
        .pose_views_i(pose_views),.pose_allviews_i(pose_allviews),
        .pose_view_i(pose_view),.pose_sequence_i(pose_sequence),.pose_tagged_i(pose_tagged),
        .hardware_tick_i(tick_ddr),.frame_id_i(frame_data_ddr[31:0]),.frame_tick_i(frame_data_ddr[63:32]),
        .display_stabilized_o(display_stabilized),.displayed_hdmi_o(displayed_hdmi),.diagnostics_valid_o(diagnostics_ddr_valid),.diagnostics_data_o(diagnostics_ddr_data),
        .displayed_source_frame_o(displayed_source_frame),.displayed_source_tick_o(displayed_source_tick),
        .requested_view_i(render_view),.requested_seq_i(requested_seq),
        .display_view_o(display_view),.display_seq_o(display_seq),
        .display_mode_i(selected_display_mode),
        .display_mode_o(active_display_mode),
        .output_refresh_tenths_o(output_refresh_tenths),
        .output_refresh_valid_o(output_refresh_valid),
        .latency_tenth_ms_o (latency_tenth_ms),
        .latency_valid_o    (latency_valid),
        .pane_first_tenths_o(pane_first_tenths),.pane_end_tenths_o(pane_end_tenths),
        .pane_first_valid_o(pane_first_valid),.pane_end_valid_o(pane_end_valid),.pane_layout_o(pane_layout),
        .capture_tenth_ms_o (capture_tenth_ms),
        .queue_tenth_ms_o   (queue_tenth_ms),
        .render_tenth_ms_o  (render_tenth_ms),
        .display_tenth_ms_o (display_tenth_ms),
        .corrected_fps_o    (corrected_fps),
        .camera_fps_tenths_o(camera_fps_tenths),
        .camera_rate_valid_o(camera_rate_valid),
        .raw_fps_o          (raw_fps),
        .render_fps_o       (render_fps),
        .init_done      (  init_done            ),//output reg                    init_done,
        .cal_write_en_i       (  1'b0               ),
        .cal_table_select_i   (  1'b0               ),
        .cal_write_addr_i     (  14'd0              ),
        .cal_write_data_i     (  48'd0              ),
        .cal_commit_i         (  1'b0               ),
        .calibration_loaded_o (                     ),
        //axi bus
        .axi_awaddr     (  axi_awaddr           ),// output[27:0]
        .axi_awid       (  axi_awuser_id        ),// output[3:0]
        .axi_awlen      (  axi_awlen            ),// output[3:0]
        .axi_awsize     (                       ),// output[2:0]
        .axi_awburst    (                       ),// output[1:0]
        .axi_awready    (  axi_awready          ),// input
        .axi_awvalid    (  axi_awvalid          ),// output               
        .axi_wdata      (  axi_wdata            ),// output[255:0]
        .axi_wstrb      (  axi_wstrb            ),// output[31:0]
        .axi_wlast      (  axi_wusero_last      ),// input
        .axi_wvalid     (                       ),// output
        .axi_wready     (  axi_wready           ),// input
        .axi_bid        (  4'd0                 ),// input[3:0]
        .axi_araddr     (  axi_araddr           ),// output[27:0]
        .axi_arid       (  axi_aruser_id        ),// output[3:0]
        .axi_arlen      (  axi_arlen            ),// output[3:0]
        .axi_arsize     (                       ),// output[2:0]
        .axi_arburst    (                       ),// output[1:0]
        .axi_arvalid    (  axi_arvalid          ),// output
        .axi_arready    (  axi_arready          ),// input
        .axi_rready     (                       ),// output
        .axi_rdata      (  axi_rdata            ),// input[255:0]
        .axi_rvalid     (  axi_rvalid           ),// input
        .axi_rlast      (  axi_rlast            ),// input
        .axi_rid        (  axi_rid              ) // input[3:0]         
    );

    // Baseline uses the same latency OSD and KEY1 enhancement path as COR.
    wire [15:0] output_rgb565=osd_rgb565;
    //==== 高阶任务三：自适应 Gamma / 直方图均衡 ====
    //  接在 fisheye_video_path 输出之后、OSD 之前；不增加 DDR 往来与帧缓冲
    //  KEY1 bypasses enhancement only; all original curves/statistics remain.
    enh_top #(
        .H_ACTIVE       ( 1280             ),
        .V_ACTIVE       ( 720              ),
        .SPLIT_X        ( 640              ),
        .WIN_X0         ( 128              ),
        .WIN_X1         ( 1152             ),
        .WIN_Y0         ( 72               ),
        .WIN_Y1         ( 648              ),
        .HE_ALPHA       ( 154              )
    ) u_enh_top (
        .pix_clk        ( pix_clk          ),
        .rst_n          ( pixel_ready_sync ),
        .vs_in          ( vs_o             ),
        .hs_in          ( hs_o             ),
        .de_in          ( de_o             ),
        .rgb_in         ( o_rgb565         ),
        .enable         ( gamma_enable ),
        .force_he       ( 1'b0             ),
        .display_mode   ( active_display_mode ),
        .win_disable    ( 1'b0             ),
        .ae_en          ( 1'b0             ),
        .de_out         ( de_enh           ),
        .rgb_out        ( rgb_enh          ),
        .mode_o         ( enh_mode         ),
        .mean_o         ( enh_mean         ),
        .dark_pct_o     ( enh_dark         ),
        .bright_pct_o   ( enh_bright       ),
        .p10_o          ( enh_p10          ),
        .p90_o          ( enh_p90          ),
        .sum_o          (                  ),
        .pix_cnt_o      (                  ),
        .hist_ready_o   (                  ),
        .busy_o         (                  )
    );

    // 同步信号与像素一起延迟 9 拍，保证 DE/HS/VS 与数据严格同拍（否则画面会右移 9 像素）
    always @(posedge pix_clk) begin
        vs_o_d1 <= vs_o;  vs_o_d2 <= vs_o_d1;  vs_o_d3 <= vs_o_d2;
        vs_o_d4 <= vs_o_d3; vs_o_d5 <= vs_o_d4; vs_o_d6 <= vs_o_d5; vs_o_d7 <= vs_o_d6; vs_o_d8 <= vs_o_d7; vs_o_d9 <= vs_o_d8;
        hs_o_d1 <= hs_o;  hs_o_d2 <= hs_o_d1;  hs_o_d3 <= hs_o_d2;
        hs_o_d4 <= hs_o_d3; hs_o_d5 <= hs_o_d4; hs_o_d6 <= hs_o_d5; hs_o_d7 <= hs_o_d6; hs_o_d8 <= hs_o_d7; hs_o_d9 <= hs_o_d8;
    end

    always @(posedge pix_clk or negedge pixel_ready_sync) begin
        if (!pixel_ready_sync)begin content_pipe<=9'b000000000;measure_content_out<=0;end
        else begin content_pipe<={content_pipe[7:0],image_content_de};measure_content_out<=content_sharp;end
    end
    assign rgb_enh_visible = content_pipe[8] ? rgb_enh : 16'd0;

    // Gamma is the last pixel filter. No sharpening line memories or
    // LINE_TOTAL+5-cycle delay remain; RGB, raster and content stay aligned.
    assign vs_sharp=vs_o_d9;
    assign hs_sharp=hs_o_d9;
    assign de_sharp=de_enh;
    assign content_sharp=content_pipe[8];
    assign rgb_sharp=rgb_enh_visible;

    // Direct HDMI presentation: suppress latency text only.
    // Keep frame marker, telemetry, image controls and RGB/DE timing unchanged.
    wire [16:0] minimum_pixel_us;
    wire minimum_pixel_valid;
    wire [6:0] minimum_pixel_layout;
    wire minimum_pixel_eligible=input_active_hdmi&&displayed_hdmi&&
        !gamma_requested&&!gamma_enable&&!stabilization_enable;
    minimum_pixel_latency_meter u_minimum_pixel_latency(
        .clock(core_clk),.reset_n(ddr_init_done),.rx_pixel_clk(hdmi_capture_clk),
        .pixel_clk(pix_clk),.pixel_reset_n(pixel_ready_sync),
        .rx_vs_i(hdmi_sample_vs),.rx_de_i(hdmi_sample_de),
        .source_qualified_i(input_active_hdmi&&hdmi_input_locked&&hdmi_source_present&&!input_switch_busy),
        .input_frame_id_async_i(frame_data_sys[31:0]),
        .following_i(output_follows_hdmi),.eligible_i(minimum_pixel_eligible),
        .vs_i(vs_out),.de_i(de_out),.content_i(measure_content_out),
        .output_frame_id_async_i(displayed_source_frame),
        .mode_async_i(active_display_mode),.view_async_i(display_view),
        .minimum_us_o(minimum_pixel_us),.minimum_valid_o(minimum_pixel_valid),
        .minimum_layout_o(minimum_pixel_layout));
    video_metrics_osd #(.LATENCY_OVERLAY_ENABLE(0),.CORRECTION_FIRST_ONLY(1),.MINIMUM_PIXEL_MODE(1)) u_video_metrics_osd (
        .first_latency_enable_i(minimum_pixel_eligible),
        .minimum_us_i(minimum_pixel_us),.minimum_valid_i(minimum_pixel_valid),.minimum_layout_i(minimum_pixel_layout),
        .panorama_marker_i(panorama_marker_requested),
        .pixel_clk(pix_clk), .reset_n(pixel_ready_sync),
        .vsync(vs_sharp), .de_in(de_sharp), .rgb_in(rgb_sharp),
        .latency_tenth_ms(latency_tenth_ms),
        .latency_valid(latency_valid),
        .pane_first_tenths_i(pane_first_tenths),.pane_end_tenths_i(pane_end_tenths),
        .pane_first_valid_i(pane_first_valid),.pane_end_valid_i(pane_end_valid),.pane_layout_i(pane_layout),
        .output_refresh_tenths(output_refresh_tenths),
        .output_refresh_valid(output_refresh_valid),
        .display_mode_async(active_display_mode),
        .view_i(display_view),
        .enhancement_enable(gamma_enable),.sharpen_enable(sharpen_enable),.stabilized_async(display_stabilized),
        .source_frame_async(displayed_source_frame),.source_tick_async(displayed_source_tick),
        .attitude_async(attitude_data),.attitude_toggle_async(attitude_toggle),.attitude_enabled_async(stabilization_enable),
        .rgb_out(osd_rgb565)
    );

    reg color_diagnostic_requested;
    always @(posedge sys_clk or negedge locked)begin
        if(!locked)color_diagnostic_requested<=0;
        else if(remote_control_valid&&(remote_control_code==8'h8c||remote_control_code==8'h8d))
            color_diagnostic_requested<=remote_control_code[0];
    end
    hdmi_color_output u_color_output(
        .clk(pix_clk),.reset_n(pixel_ready_sync),
        .vs_i(vs_sharp),.hs_i(hs_sharp),.de_i(de_sharp),.rgb_i(output_rgb565),
        .diagnostic_async_i(color_diagnostic_requested),.diagnostic_active_o(static_test_camera),
        .r_o(r_out),.g_o(g_out),.b_o(b_out),.vs_o(vs_out),.hs_o(hs_out),.de_o(de_out));

/////////////////////////////////////////////////////////////////////////////////////
//浜х敓visa鏃跺簭 
     // DDR calibration is asynchronous to the HDMI pixel clock.
     wire output_domain_reset_n=output_clock_reset_n&&raster_enable;
     always @(posedge pix_clk or negedge output_domain_reset_n) begin
         if(!output_domain_reset_n)begin pixel_ready_meta<=0;pixel_ready_sync<=0;end
         else begin pixel_ready_meta <= ddr_init_done;pixel_ready_sync <= pixel_ready_meta;end
     end
     sync_vg sync_vg(                            
        .clk            (  pix_clk              ),//input                   clk,                                 
        .rstn           (  pixel_ready_sync     ),//input                   rstn,                            
         .phase_adjust_i (raster_phase_adjust),
        .vs_out         (  vs_o                 ),//output wire              vs_out,                                                                                                                                      
        .hs_out         (  hs_o                 ),//output wire              hs_out,            
        .de_out         (  de_re                     ),//output wire              de_out, 
        .de_re          (                  ),
        .frame_end_o    (raster_frame_end)    
    );  
////////////////////////////////////////////////////////////////////////////////////////////
//ddr    
/*        ddr3_100h ddr3_100h (
             .ref_clk                   (sys_clk            ),
             .resetn                    (rstn_out           ),// input
             .ddr_init_done             (ddr_init_done      ),// output
             .ddrphy_clkin              (core_clk           ),// output
             .pll_lock                  (pll_lock           ),// output

             .axi_awaddr                (axi_awaddr         ),// input [27:0]
             .axi_awuser_ap             (1'b0               ),// input
             .axi_awuser_id             (axi_awuser_id      ),// input [3:0]
             .axi_awlen                 (axi_awlen          ),// input [3:0]
             .axi_awready               (axi_awready        ),// output
             .axi_awvalid               (axi_awvalid        ),// input
             .axi_wdata                 (axi_wdata          ),
             .axi_wstrb                 (axi_wstrb          ),// input [31:0]
             .axi_wready                (axi_wready         ),// output
             .axi_wusero_id             (                   ),// output [3:0]
             .axi_wusero_last           (axi_wusero_last    ),// output
             .axi_araddr                (axi_araddr         ),// input [27:0]
             .axi_aruser_ap             (1'b0               ),// input
             .axi_aruser_id             (axi_aruser_id      ),// input [3:0]
             .axi_arlen                 (axi_arlen          ),// input [3:0]
             .axi_arready               (axi_arready        ),// output
             .axi_arvalid               (axi_arvalid        ),// input
             .axi_rdata                 (axi_rdata          ),// output [255:0]
             .axi_rid                   (axi_rid            ),// output [3:0]
             .axi_rlast                 (axi_rlast          ),// output
             .axi_rvalid                (axi_rvalid         ),// output

             .apb_clk                   (1'b0               ),// input
             .apb_rst_n                 (1'b1               ),// input
             .apb_sel                   (1'b0               ),// input
             .apb_enable                (1'b0               ),// input
             .apb_addr                  (8'b0               ),// input [7:0]
             .apb_write                 (1'b0               ),// input
             .apb_ready                 (                   ), // output
             .apb_wdata                 (16'b0              ),// input [15:0]
             .apb_rdata                 (                   ),// output [15:0]
             .apb_int                   (                   ),// output

             .mem_rst_n                 (mem_rst_n          ),// output
             .mem_ck                    (mem_ck             ),// output
             .mem_ck_n                  (mem_ck_n           ),// output
             .mem_cke                   (mem_cke            ),// output
             .mem_cs_n                  (mem_cs_n           ),// output
             .mem_ras_n                 (mem_ras_n          ),// output
             .mem_cas_n                 (mem_cas_n          ),// output
             .mem_we_n                  (mem_we_n           ),// output
             .mem_odt                   (mem_odt            ),// output
             .mem_a                     (mem_a              ),// output [14:0]
             .mem_ba                    (mem_ba             ),// output [2:0]
             .mem_dqs                   (mem_dqs            ),// inout [3:0]
             .mem_dqs_n                 (mem_dqs_n          ),// inout [3:0]
             .mem_dq                    (mem_dq             ),// inout [31:0]
             .mem_dm                    (mem_dm             ),// output [3:0]
             //debug
             .debug_data                (                   ),// output [135:0]
             .debug_slice_state         (                   ),// output [51:0]
             .debug_calib_ctrl          (                   ),// output [21:0]
             .ck_dly_set_bin            (                   ),// output [7:0]
             .force_ck_dly_en           (1'b0               ),// input
             .force_ck_dly_set_bin      (8'h05              ),// input [7:0]
             .dll_step                  (                   ),// output [7:0]
             .dll_lock                  (                   ),// output
             .init_read_clk_ctrl        (2'b0               ),// input [1:0]
             .init_slip_step            (4'b0               ),// input [3:0]
             .force_read_clk_ctrl       (1'b0               ),// input
             .ddrphy_gate_update_en     (1'b0               ),// input
             .update_com_val_err_flag   (                   ),// output [3:0]
             .rd_fake_stop              (1'b0               ) // input
       );*/
wire clk_125Mhz ;
// Release the DDR PHY reset on its 125 MHz reference clock, not on cfg_clk.
// The external reference continues running while the DDR PLL is in reset.
reg [2:0] ddr_reset_sync = 3'b000;
always @(posedge clk_125Mhz) begin
    if (!rstn_out)
        ddr_reset_sync <= 3'b000;
    else
        ddr_reset_sync <= {ddr_reset_sync[1:0], 1'b1};
end

GTP_INBUFGDS #(
    .IOSTANDARD("DEFAULT"),
    .TERM_DIFF("ON")
) u_gtp (
    .O(clk_125Mhz), // OUTPUT  
    .I(clk_p), // INPUT  
    .IB(clk_n) // INPUT  
);
 ddr3_test u_ddr3_test_h(
             .ref_clk                   (clk_125Mhz            ),
             .resetn                    (ddr_reset_sync[2]  ),// input
             .ddr_init_done             (ddr_init_done      ),// output

             .pll_lock                  (pll_lock           ),// output

             .core_clk                  (core_clk),                                  // output

             .phy_pll_lock              (phy_pll_lock),                          // output
             .gpll_lock                 (gpll_lock),                                // output
             .rst_gpll_lock             (rst_gpll_lock),                        // output
             .ddrphy_cpd_lock           (ddrphy_cpd_lock),                    // output
             //.ddr_init_done             (ddr_init_done),                        // output


             .axi_awaddr                (axi_awaddr         ),// input [27:0]
             .axi_awuser_ap             (1'b0               ),// input
             .axi_awuser_id             (axi_awuser_id      ),// input [3:0]
             .axi_awlen                 (axi_awlen          ),// input [3:0]
             .axi_awready               (axi_awready        ),// output
             .axi_awvalid               (axi_awvalid        ),// input
             .axi_wdata                 (axi_wdata          ),
             .axi_wstrb                 (axi_wstrb          ),// input [31:0]
             .axi_wready                (axi_wready         ),// output
             .axi_wusero_id             (                   ),// output [3:0]
             .axi_wusero_last           (axi_wusero_last    ),// output
             .axi_araddr                (axi_araddr         ),// input [27:0]
             .axi_aruser_ap             (1'b0               ),// input
             .axi_aruser_id             (axi_aruser_id      ),// input [3:0]
             .axi_arlen                 (axi_arlen          ),// input [3:0]
             .axi_arready               (axi_arready        ),// output
             .axi_arvalid               (axi_arvalid        ),// input
             .axi_rdata                 (axi_rdata          ),// output [255:0]
             .axi_rid                   (axi_rid            ),// output [3:0]
             .axi_rlast                 (axi_rlast          ),// output
             .axi_rvalid                (axi_rvalid         ),// output

             .apb_clk                   (1'b0               ),// input
             .apb_rst_n                 (1'b1               ),// input
             .apb_sel                   (1'b0               ),// input
             .apb_enable                (1'b0               ),// input
             .apb_addr                  (8'b0               ),// input [7:0]
             .apb_write                 (1'b0               ),// input
             .apb_ready                 (                   ), // output
             .apb_wdata                 (16'b0              ),// input [15:0]
             .apb_rdata                 (                   ),// output [15:0]
//             .apb_int                   (                   ),// output

             .mem_rst_n                 (mem_rst_n          ),// output
             .mem_ck                    (mem_ck             ),// output
             .mem_ck_n                  (mem_ck_n           ),// output
             .mem_cke                   (mem_cke            ),// output
             .mem_cs_n                  (mem_cs_n           ),// output
             .mem_ras_n                 (mem_ras_n          ),// output
             .mem_cas_n                 (mem_cas_n          ),// output
             .mem_we_n                  (mem_we_n           ),// output
             .mem_odt                   (mem_odt            ),// output
             .mem_a                     (mem_a              ),// output [14:0]
             .mem_ba                    (mem_ba             ),// output [2:0]
             .mem_dqs                   (mem_dqs            ),// inout [3:0]
             .mem_dqs_n                 (mem_dqs_n          ),// inout [3:0]
             .mem_dq                    (mem_dq             ),// inout [31:0]
             .mem_dm                    (mem_dm             ),// output [3:0]
             //debug

  .dbg_gate_start(1'b0),                      // input
  .dbg_cpd_start(1'b0),                        // input
  .dbg_ddrphy_rst_n(1'b1),                  // input
  .dbg_gpll_scan_rst(1'b0),                // input
  .samp_position_dyn_adj(1'b0),        // input
  .init_samp_position_even(32'd0),    // input [31:0]
  .init_samp_position_odd(32'd0),      // input [31:0]
  .wrcal_position_dyn_adj(1'b0),      // input
  .init_wrcal_position(32'd0),            // input [31:0]
  .force_read_clk_ctrl(1'b0),            // input
  .init_slip_step(16'd0),                      // input [15:0]
  .init_read_clk_ctrl(12'd0),              // input [11:0]
  .debug_calib_ctrl(),                  // output [33:0]
  .dbg_slice_status(),                  // output [67:0]
  .dbg_slice_state(),                    // output [87:0]
  .debug_data(),                              // output [275:0]
  .dbg_dll_upd_state(),                // output [1:0]
  .debug_gpll_dps_phase(),          // output [8:0]
  .dbg_rst_dps_state(),                // output [2:0]
  .dbg_tran_err_rst_cnt(),          // output [5:0]
  .dbg_ddrphy_init_fail(),          // output
  .debug_cpd_offset_adj(1'b0),          // input
  .debug_cpd_offset_dir(1'b0),          // input
  .debug_cpd_offset(10'd0),                  // input [9:0]
  .debug_dps_cnt_dir0(),              // output [9:0]
  .debug_dps_cnt_dir1(),              // output [9:0]
  .ck_dly_en(1'b0),                                // input
  .init_ck_dly_step(8'h0),                  // input [7:0]
  .ck_dly_set_bin(),                      // output [7:0]
  .align_error(),                            // output
  .debug_rst_state(),                    // output [3:0]
  .debug_cpd_state()                     // output [3:0]
       );
//蹇冭烦淇″彿
     always@(posedge core_clk) begin
        if (!ddr_init_done)
            cnt <= 27'd0;
        else if ( cnt >= TH_1S )
            cnt <= 27'd0;
        else
            cnt <= cnt + 27'd1;
     end

     always @(posedge core_clk)
        begin
        if (!ddr_init_done)
            heart_beat_led <= 1'd1;
        else if ( cnt >= TH_1S )
            heart_beat_led <= ~heart_beat_led;
    end
                 
/////////////////////////////////////////////////////////////////////////////////////
endmodule
