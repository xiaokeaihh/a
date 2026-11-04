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
//camera中寄存器的配置程序
 module reg_config #(
          parameter integer I2C_HALF_CYCLES = 1250,
          parameter integer REVERSE_CAPTURE = 0,
          parameter integer RETRY_BACKOFF_CYCLES = 1000
      )(     
		  input clk_25M,
		  input camera_rstn,
		  input initial_en,
		  output reg_conf_done,
		  output i2c_sclk,
		  inout i2c_sdat,
		  output reg clock_20k,
		  output reg [8:0]reg_index,
          input auto_exposure_i,
          input high_exposure_i,
          input auto_white_balance_i,
          output reg auto_white_balance_applied_o,auto_white_balance_busy_o,auto_white_balance_error_o,
          output reg high_exposure_applied_o,
          output reg auto_exposure_applied_o,
          output reg auto_exposure_busy_o,
          output reg auto_exposure_error_o,
          input meter_valid_i, input [1:0] meter_direction_i,
          input meter_fast_i, meter_toggle_i
	  );

     // Fixed capture settings for the 720p30 camera. Adjust for the actual
     // lighting before calibration; 0x0400 is unity AWB channel gain.
     // Exposure is in whole sensor lines (VTS = 740; keep below 736).
     localparam [15:0] FIXED_EXPOSURE_LINES = 16'd500; // about 22.5 ms, +12.6% over 444 lines
     localparam [9:0]  FIXED_SENSOR_GAIN_X16 = 10'h020; // 2.0x
     // Starting gains only. Advanced sensor AWB remains enabled in both exposure modes.
     localparam [11:0] FIXED_WB_R = 12'h61c;
     localparam [11:0] FIXED_WB_G = 12'h400;
     localparam [11:0] FIXED_WB_B = 12'h4f3;
     localparam [19:0] FIXED_EXPOSURE_REG = {FIXED_EXPOSURE_LINES, 4'b0000};

     reg [15:0]clock_20k_cnt;
     reg [1:0]config_step;	  
     reg [31:0]i2c_data;
     reg [23:0]reg_data;
     reg start;
     wire ack, tr_end;
     reg ae_meta, ae_sync, high_meta, high_sync;
     reg [1:0] ae_target;
     reg awb_meta,awb_sync,awb_target,awb_transaction;
     wire [1:0] exposure_mode=high_sync?2'd2:ae_sync?2'd1:2'd0;
     reg [2:0] ae_state;
     reg [3:0] ae_index;
     reg [2:0] ae_retries;
     reg ae_retry;
     localparam integer BACKOFF_BITS = RETRY_BACKOFF_CYCLES > 1 ? $clog2(RETRY_BACKOFF_CYCLES) : 1;
     reg [BACKOFF_BITS-1:0] ae_backoff;

     // A strict exposure-priority controller owns both sensor registers.
     // One line is nominally 45 us at HTS=1892 / 42 MHz, camera stays 30 fps.
     localparam [15:0] AE_MAX_LINES=16'd710, AE_MIN_LINES=16'd4;
     localparam [15:0] AE_START_LINES=16'd444, HIGH_EXPOSURE_LINES=16'd710;
     localparam [9:0] HIGH_SENSOR_GAIN_X16=10'd32; // Fixed 2x: compare Gamma without an exposure feedback loop.
     localparam [9:0] AE_MIN_GAIN=10'd16, AE_MAX_GAIN=10'd64;
     reg [15:0] exposure_lines, pending_lines;
     reg [9:0] sensor_gain_x16, pending_gain;
     reg [2:0] meter_toggle_sync;
     reg [3:0] meter_flags_meta,meter_flags_sync;
     reg meter_seen;
     reg [1:0] settle_frames;
     wire [19:0] pending_exposure={pending_lines,4'b0000};
     reg [15:0] next_lines, exposure_step;
     reg [9:0] next_gain, gain_step;
     always @* begin
         next_lines=exposure_lines;next_gain=sensor_gain_x16;
         exposure_step=exposure_lines>>(meter_flags_sync[0]?2:3);
         gain_step=sensor_gain_x16>>(meter_flags_sync[0]?2:3);
         if(exposure_step==0)exposure_step=1;
         if(gain_step==0)gain_step=1;
         if(meter_flags_sync[2:1]==2'd1)begin
             if(exposure_lines<AE_MAX_LINES)begin
                 if(exposure_lines+exposure_step>=AE_MAX_LINES)next_lines=AE_MAX_LINES;
                 else next_lines=exposure_lines+exposure_step;
             end else if(sensor_gain_x16<AE_MAX_GAIN)begin
                 if(sensor_gain_x16+gain_step>=AE_MAX_GAIN)next_gain=AE_MAX_GAIN;
                 else next_gain=sensor_gain_x16+gain_step;
             end
         end else if(meter_flags_sync[2:1]==2'd2)begin
             if(sensor_gain_x16>AE_MIN_GAIN)begin
                 if(sensor_gain_x16<=AE_MIN_GAIN+gain_step)next_gain=AE_MIN_GAIN;
                 else next_gain=sensor_gain_x16-gain_step;
             end else if(exposure_lines>AE_MIN_LINES)begin
                 if(exposure_lines<=AE_MIN_LINES+exposure_step)next_lines=AE_MIN_LINES;
                 else next_lines=exposure_lines-exposure_step;
             end
         end
     end
     // Group launch applies exposure and gain together on a sensor boundary.
     function [23:0] exposure_word;
         input [3:0] number;
         begin
             case(number)
                 0: exposure_word=24'h321200;
                 1: exposure_word=24'h350303; // FPGA owns AEC and AGC
                 2: exposure_word={16'h3500,4'd0,pending_exposure[19:16]};
                 3: exposure_word={16'h3501,pending_exposure[15:8]};
                 4: exposure_word={16'h3502,pending_exposure[7:0]};
                 5: exposure_word={16'h350a,6'd0,pending_gain[9:8]};
                 6: exposure_word={16'h350b,pending_gain[7:0]};
                 7: exposure_word=24'h321210;
                 8: exposure_word=24'h3212a0;
                 default: exposure_word=24'h321210;
             endcase
         end
     endfunction

	 reg reg_conf_done_reg;
	  
     i2c_com u1(.clock_i2c(clock_20k),
               .camera_rstn(camera_rstn),
               .ack(ack),
               .i2c_data(i2c_data),
               .start(start),
               .tr_end(tr_end),
               .i2c_sclk(i2c_sclk),
               .i2c_sdat(i2c_sdat));

// Only a held mode level crosses domains. Keep a complete in-flight bundle.
always @(posedge clock_20k or negedge camera_rstn) begin
    if(!camera_rstn)begin
        ae_meta<=0;ae_sync<=0;high_meta<=0;high_sync<=0;awb_meta<=1;awb_sync<=1;meter_toggle_sync<=0;meter_flags_meta<=0;meter_flags_sync<=0;
    end else begin
        ae_meta<=auto_exposure_i;ae_sync<=ae_meta;
        high_meta<=high_exposure_i;high_sync<=high_meta;
        awb_meta<=auto_white_balance_i;awb_sync<=awb_meta;
        meter_toggle_sync<={meter_toggle_sync[1:0],meter_toggle_i};
        meter_flags_meta<={meter_valid_i,meter_direction_i,meter_fast_i};
        meter_flags_sync<=meter_flags_meta;
    end
end
assign reg_conf_done=reg_conf_done_reg;
//产生i2c控制时钟-20khz    
always@(posedge clk_25M)   
begin
   if(!camera_rstn) begin
        clock_20k<=0;
        clock_20k_cnt<=0;
   end
   else if(clock_20k_cnt<I2C_HALF_CYCLES-1)
      clock_20k_cnt<=clock_20k_cnt+1'b1;
   else begin
         clock_20k<=!clock_20k;
         clock_20k_cnt<=0;
   end
end


////iic寄存器配置过程控制    
always@(posedge clock_20k or negedge camera_rstn)
begin
   if(!camera_rstn) begin
       config_step<=0;
       start<=0;
       reg_index<=0;
       i2c_data<=0;
       ae_target<=0;awb_target<=1;awb_transaction<=0;ae_state<=0;ae_index<=0;ae_retries<=0;ae_retry<=0;ae_backoff<=0;
       exposure_lines<=FIXED_EXPOSURE_LINES;pending_lines<=FIXED_EXPOSURE_LINES;
       sensor_gain_x16<=FIXED_SENSOR_GAIN_X16;pending_gain<=FIXED_SENSOR_GAIN_X16;
       meter_seen<=0;settle_frames<=0;
       auto_exposure_applied_o<=0;high_exposure_applied_o<=0;
       auto_white_balance_applied_o<=1;auto_white_balance_busy_o<=0;auto_white_balance_error_o<=0;auto_exposure_busy_o<=0;auto_exposure_error_o<=0;

		 reg_conf_done_reg<=0;
   end
   else begin
      if(reg_conf_done_reg==1'b0) begin          //如果camera初始化未完成
			  if(reg_index<371) begin               //配置寄存器
					 case(config_step)
					 0:begin
						i2c_data<={8'h78,reg_data};       //OV5640 IIC Device address is 0x78   
						start<=1;                         //i2c写开始
						config_step<=1;                  
					 end
					 1:begin
						if(tr_end) begin                  //i2c写结束               					
							 start<=0;
							 config_step<=2;
						end
					 end
					 2:begin
						  reg_index<=reg_index+1'b1;       //配置下一个寄存器
						  config_step<=0;
					 end
					 endcase
				end
			 else 
				reg_conf_done_reg<=1'b1;                //OV5640寄存器初始化完成
      end else begin
          // Initialization stays asserted throughout all subsequent updates.
          case(ae_state)
              0: begin
                  start<=0;
                  if(exposure_mode != {high_exposure_applied_o,auto_exposure_applied_o}) begin
                      awb_transaction<=0;ae_target<=exposure_mode;ae_index<=0;ae_retries<=0;
                      pending_lines<=high_sync?HIGH_EXPOSURE_LINES:ae_sync?AE_START_LINES:FIXED_EXPOSURE_LINES;
                      pending_gain<=high_sync?HIGH_SENSOR_GAIN_X16:ae_sync?AE_MIN_GAIN:FIXED_SENSOR_GAIN_X16;
                      meter_seen<=meter_toggle_sync[2];
                      auto_exposure_busy_o<=1;auto_exposure_error_o<=0;ae_state<=1;
                  end else if(awb_sync!=auto_white_balance_applied_o)begin
                      // Freeze the converged AWB gains without replacing them with a preset.
                      awb_transaction<=1;awb_target<=awb_sync;ae_index<=0;ae_retries<=0;
                      auto_white_balance_busy_o<=1;auto_white_balance_error_o<=0;ae_state<=1;
                  end else if(meter_toggle_sync[2]!=meter_seen)begin
                      meter_seen<=meter_toggle_sync[2];
                      if(settle_frames!=0)settle_frames<=settle_frames-1'b1;
                      else if(exposure_mode==2'd1&&meter_flags_sync[3]&&
                              ((next_lines!=exposure_lines)||(next_gain!=sensor_gain_x16)))begin
                          pending_lines<=next_lines;pending_gain<=next_gain;
                          awb_transaction<=0;ae_target<=1;ae_index<=0;ae_retries<=0;
                          auto_exposure_busy_o<=1;auto_exposure_error_o<=0;ae_state<=1;
                      end
                  end
              end
              1: begin
                  i2c_data<=awb_transaction?{8'h78,16'h5196,(awb_target?8'h03:8'h23)}:{8'h78,exposure_word(ae_index)};
                  start<=1;ae_state<=2;
              end
              2: if(tr_end) begin
                  start<=0;
                  ae_retry<=ack;
                  if(ack) begin
                      if(ae_retries==3'd7) begin
                          if(awb_transaction)auto_white_balance_error_o<=1;else auto_exposure_error_o<=1;
                          ae_backoff<=0;ae_state<=4;
                      end else begin ae_retries<=ae_retries+1'b1;ae_state<=3;end
                  end else begin ae_retries<=0;
                      if(awb_transaction)auto_white_balance_error_o<=0;else auto_exposure_error_o<=0;ae_state<=3;end
              end
              3: begin
                  // One low-start cycle resets the bus engine before reloading.
                  if(ae_retry) ae_state<=1;
                  else if(awb_transaction||ae_index==4'd8) begin
                      if(awb_transaction)begin
                          auto_white_balance_applied_o<=awb_target;auto_white_balance_busy_o<=0;
                      end else begin
                      auto_exposure_applied_o<=(ae_target==2'd1);
                      high_exposure_applied_o<=(ae_target==2'd2);
                      exposure_lines<=pending_lines;sensor_gain_x16<=pending_gain;
                      meter_seen<=meter_toggle_sync[2];settle_frames<=2;
                      auto_exposure_busy_o<=0;
                      end
                      ae_state<=0;
                  end else begin ae_index<=ae_index+1'b1;ae_state<=1;end
              end
              4: begin
                  // An absent sensor must not stall the video or flood the bus.
                  if(ae_backoff==RETRY_BACKOFF_CYCLES-1) begin
                      ae_retries<=0;ae_state<=1;
                  end else ae_backoff<=ae_backoff+1'b1;
              end
              default: begin start<=0;ae_state<=0;end
          endcase
      end
   end
 end
			
////iic需要配置的寄存器值  			
always@(reg_index)   
 begin
    case(reg_index)
	 0    :reg_data   <=24'h310311 ;//      
	 1    :reg_data   <=24'h300882 ;//      

	 102  :reg_data   <=24'h300842 ;//      
	 103  :reg_data   <=24'h310303 ;//      
	 104  :reg_data   <=24'h3017ff ;//      
	 105  :reg_data   <=24'h3018ff ;//      
	 106  :reg_data   <=24'h30341A ;//      
	 107  :reg_data   <=24'h303713 ;//      
	 108  :reg_data   <=24'h310801 ;//      
	 109  :reg_data   <=24'h363036 ;//      
	 110  :reg_data  <=24'h36310e ;//       
	 111  :reg_data  <=24'h3632e2 ;//       
	 112  :reg_data  <=24'h363312 ;//       
	 113  :reg_data  <=24'h3621e0 ;//       
	 114  :reg_data  <=24'h3704a0 ;//       
	 115  :reg_data  <=24'h37035a ;//       
	 116  :reg_data  <=24'h371578 ;//       
	 117  :reg_data  <=24'h371701 ;//       
	 118  :reg_data  <=24'h370b60 ;//       
	 119  :reg_data  <=24'h37051a ;//       
	 120  :reg_data  <=24'h390502 ;//       
	 121  :reg_data  <=24'h390610 ;//       
	 122  :reg_data  <=24'h39010a ;//       
	 123  :reg_data  <=24'h373112 ;//       
	 124  :reg_data  <=24'h360008 ;//       
	 125  :reg_data  <=24'h360133 ;//       
	 126  :reg_data  <=24'h302d60 ;//       
	 127  :reg_data  <=24'h362052 ;//       
	 128  :reg_data  <=24'h371b20 ;//       
	 129  :reg_data  <=24'h471c50 ;//       
	 130  :reg_data  <=24'h3a1343 ;//       
	 131  :reg_data  <=24'h3a1800 ;//       
	 132  :reg_data  <=24'h3a1940 ;//       
	 133  :reg_data  <=24'h363513 ;//       
	 134  :reg_data  <=24'h363603 ;//       
	 135  :reg_data  <=24'h363440 ;//       
	 136  :reg_data  <=24'h362201 ;///      
	 137  :reg_data  <=24'h3c0134 ;//       
	 138  :reg_data  <=24'h3c0428 ;//       
	 139  :reg_data  <=24'h3c0598 ;//       
	 140  :reg_data  <=24'h3c0600 ;//       
     141  :reg_data  <=24'h3c0708 ;//       
	 142  :reg_data  <=24'h3c0800 ;//       
	 143  :reg_data  <=24'h3c091c ;//       
	 144  :reg_data  <=24'h3c0a9c ;//       
	 145  :reg_data  <=24'h3c0b40 ;//       
	 146  :reg_data  <=24'h381000 ;//       
	 147  :reg_data  <=24'h381110 ;//       
	 148  :reg_data  <=24'h381200 ;//       
	 149  :reg_data  <=24'h370864 ;//       
	 150  :reg_data  <=24'h400102 ;//       
	 151  :reg_data  <=24'h40051a ;//       
	 152  :reg_data  <=24'h300000 ;//       
	 153  :reg_data  <=24'h3004ff ;//       
	 154  :reg_data  <=24'h300e58 ;//       
	 155  :reg_data  <=24'h302e00 ;//       
	 156  :reg_data  <=24'h430060 ;//       
	 157  :reg_data  <=24'h501f01 ;//       
	 158  :reg_data  <=24'h440e00 ;//       
	 159  :reg_data  <=24'h5000a7 ;//     
	 160  :reg_data  <=24'h3a0f30 ;//       
	 161  :reg_data  <=24'h3a1028 ;//       
	 162  :reg_data  <=24'h3a1b30 ;//       
	 163  :reg_data  <=24'h3a1e26 ;//       
	 164  :reg_data  <=24'h3a1160 ;//       
	 165  :reg_data  <=24'h3a1f14 ;//       
	 166  :reg_data  <=24'h580023 ;//       
	 167  :reg_data  <=24'h580114 ;//       
	 168  :reg_data  <=24'h58020f ;//       
	 169  :reg_data  <=24'h58030f ;//       
	 170  :reg_data  <=24'h580412 ;//       
	 171  :reg_data  <=24'h580526 ;//       
	 172  :reg_data  <=24'h58060c ;//       
	 173  :reg_data  <=24'h580708 ;//       
	 174  :reg_data  <=24'h580805 ;//       
	 175  :reg_data  <=24'h580905 ;//       
	 176  :reg_data  <=24'h580a08 ;//       
	 177  :reg_data  <=24'h580b0d ;//       
	 178  :reg_data  <=24'h580c08 ;//       
	 179  :reg_data  <=24'h580d03 ;//       
	 180  :reg_data  <=24'h580e00 ;//       
	 181  :reg_data  <=24'h580f00 ;//       
	 182  :reg_data  <=24'h581003 ;//       
	 183  :reg_data  <=24'h581109 ;//       
	 184  :reg_data  <=24'h581207 ;//       
	 185  :reg_data  <=24'h581303 ;//       
	 186  :reg_data  <=24'h581400 ;//       
	 187  :reg_data  <=24'h581501 ;//       
	 188  :reg_data  <=24'h581603 ;//       
	 189  :reg_data  <=24'h581708 ;//       
	 190  :reg_data  <=24'h58180d ;//       
	 191  :reg_data  <=24'h581908 ;//       
	 192  :reg_data  <=24'h581a05 ;//       
	 193  :reg_data  <=24'h581b06 ;//       
	 194  :reg_data  <=24'h581c08 ;//       
	 195  :reg_data  <=24'h581d0e ;//       
	 196  :reg_data  <=24'h581e29 ;//       
	 197  :reg_data  <=24'h581f17 ;//       
	 198  :reg_data  <=24'h582011 ;//       
	 199  :reg_data  <=24'h582111 ;//       
	 200  :reg_data <=24'h582215 ;//        
	 201  :reg_data <=24'h582328 ;//        
	 202  :reg_data <=24'h582446 ;//        
	 203  :reg_data <=24'h582526 ;//        
	 204  :reg_data <=24'h582608 ;//        
	 205  :reg_data <=24'h582726 ;//        
	 206  :reg_data <=24'h582864 ;//        
	 207  :reg_data <=24'h582926 ;//        
	 208  :reg_data <=24'h582a24 ;//        
	 209  :reg_data <=24'h582b22 ;//        
	 210  :reg_data <=24'h582c24 ;//        
	 211  :reg_data <=24'h582d24 ;//        
	 212  :reg_data <=24'h582e06 ;//        
	 213  :reg_data <=24'h582f22 ;//        
	 214  :reg_data <=24'h583040 ;//        
	 215  :reg_data <=24'h583142 ;//        
	 216  :reg_data <=24'h583224 ;//        
	 217  :reg_data <=24'h583326 ;//        
	 218  :reg_data <=24'h583424 ;//        
	 219  :reg_data <=24'h583522 ;//        
	 220  :reg_data <=24'h583622 ;//        
	 221  :reg_data <=24'h583726 ;//        
	 222  :reg_data <=24'h583844 ;//        
	 223  :reg_data <=24'h583924 ;//        
	 224  :reg_data <=24'h583a26 ;//        
	 225  :reg_data <=24'h583b28 ;//        
	 226  :reg_data <=24'h583c42 ;//        
	 227  :reg_data <=24'h583dce ;//        
	 228  :reg_data <=24'h5180ff ;//        
	 229  :reg_data <=24'h5181f2 ;//        
	 230  :reg_data <=24'h518200 ;//        
	 231  :reg_data <=24'h518314 ;//        
	 232  :reg_data <=24'h518425 ;//        
	 233  :reg_data <=24'h518524 ;//        
	 234  :reg_data <=24'h518609 ;//        
	 235  :reg_data <=24'h518709 ;//        
	 236  :reg_data <=24'h518809 ;//        
	 237  :reg_data <=24'h518975 ;//        
	 238  :reg_data <=24'h518a54 ;//        
	 239  :reg_data <=24'h518be0 ;//        
	 240  :reg_data <=24'h518cb2 ;//        
	 241  :reg_data <=24'h518d42 ;//        
	 242  :reg_data <=24'h518e3d ;//        
	 243  :reg_data <=24'h518f56 ;//        
	 244  :reg_data <=24'h519046 ;//        
	 245  :reg_data <=24'h5191f8 ;//        
	 246  :reg_data <=24'h519204 ;//        
	 247  :reg_data <=24'h519370 ;//        
	 248  :reg_data <=24'h5194f0 ;//        
	 249  :reg_data <=24'h5195f0 ;//        
	 250  :reg_data <=24'h519603 ;//        
	 251  :reg_data <=24'h519701 ;//        
	 252  :reg_data <=24'h519804 ;//        
	 253  :reg_data <=24'h519912 ;//        
	 254  :reg_data <=24'h519a04 ;//        
	 255  :reg_data <=24'h519b00 ;//        
	 256  :reg_data <=24'h519c06 ;//        
	 257  :reg_data <=24'h519d82 ;//        
	 258  :reg_data <=24'h519e38 ;//        
	 259  :reg_data <=24'h548001 ;//        
	 260  :reg_data <=24'h548108 ;//        
	 261  :reg_data <=24'h548214 ;//        
	 262  :reg_data <=24'h548328 ;//        
	 263  :reg_data <=24'h548451 ;//        
	 264  :reg_data <=24'h548565 ;//        
	 265  :reg_data <=24'h548671 ;//        
	 266  :reg_data <=24'h54877d ;//        
	 267  :reg_data <=24'h548887 ;//        
	 268  :reg_data <=24'h548991 ;//        
	 269  :reg_data <=24'h548a9a ;//        
	 270  :reg_data <=24'h548baa ;//        
	 271  :reg_data <=24'h548cb8 ;//        
	 272  :reg_data <=24'h548dcd ;//        
	 273  :reg_data <=24'h548edd ;//        
	 274  :reg_data <=24'h548fea ;//        
	 275  :reg_data <=24'h54901d ;//        
	 276  :reg_data <=24'h53811e ;//        
	 277  :reg_data <=24'h53825b ;//        
	 278  :reg_data <=24'h538308 ;//        
	 279  :reg_data <=24'h53840a ;//        
	 280  :reg_data <=24'h53857e ;//        
	 281  :reg_data <=24'h538688 ;//        
	 282  :reg_data <=24'h53877c ;//        
	 283  :reg_data <=24'h53886c ;//        
	 284  :reg_data <=24'h538910 ;//        
	 285  :reg_data <=24'h538a01 ;//        
	 286  :reg_data <=24'h538b98 ;//       
	 287  :reg_data <=24'h558006 ;//        
	 288  :reg_data <=24'h558340 ;//        
	 289  :reg_data <=24'h558410 ;//        
	 290  :reg_data <=24'h558910 ;//        
	 291  :reg_data <=24'h558a00 ;//        
	 292  :reg_data <=24'h558bf8 ;//        
	 293  :reg_data <=24'h501d40 ;//        
	 294  :reg_data <=24'h530008 ;//        
	 295  :reg_data <=24'h530130 ;//        
	 296  :reg_data <=24'h530210 ;//        
	 297  :reg_data <=24'h530300 ;//        
	 298  :reg_data <=24'h530408 ;//        
	 299  :reg_data <=24'h530530 ;//        
	 300  :reg_data <=24'h530608 ;//        
	 301  :reg_data <=24'h530716 ;//        
	 302  :reg_data <=24'h530908 ;//        
	 303  :reg_data <=24'h530a30 ;//        
	 304  :reg_data <=24'h530b04 ;//        
	 305  :reg_data <=24'h530c06 ;//        
	 306  :reg_data <=24'h502500 ;//        
	 307  :reg_data <=24'h300842 ;// stop streaming before changing video timing
  // The DOUBLE-DVP-OV5640 daughterboard drives both sensors from its own
  // 24.00 MHz oscillator. The OV5640 720p30 reference uses multiplier 105
  // (0x69), HTS 1892 and VTS 740 for a nominal 30.0 fps.
	 308  :reg_data <=24'h303521 ;// system clock divider
	 309  :reg_data <=24'h303669 ;// PLL multiplier 105 for 24 MHz XCLK
     310  :reg_data <=24'h3c0707 ;//
	 311  :reg_data <= REVERSE_CAPTURE ? 24'h382045 : 24'h382043; // toggle sensor+ISP VFLIP together; DDR reverses rows back
	 312  :reg_data <=24'h382105 ;// 720p subsampling plus prior horizontal orientation
	 313  :reg_data <=24'h381431 ;// 2x2 subsampling
	 314  :reg_data <=24'h381531 ;// 2x2 subsampling
	 315  :reg_data <=24'h380000 ;// source window X start
	 316  :reg_data <=24'h380100 ;//
	 317  :reg_data <=24'h380200 ;// source window Y start
	 318  :reg_data <=24'h3803fa ;//
	 319  :reg_data <=24'h38040a ;// source window X end
	 320  :reg_data <=24'h38053f ;//
	 321  :reg_data <=24'h380606 ;// source window Y end
	 322  :reg_data <=24'h3807a9 ;//
	 323  :reg_data <=24'h380805 ;// 1280 output width high
	 324  :reg_data <=24'h380900 ;// 1280 output width low
	 325  :reg_data <=24'h380a02 ;// 720 output height high
	 326  :reg_data <=24'h380bd0 ;// 720 output height low
	 327  :reg_data <=24'h380c07 ;// HTS 1892
	 328  :reg_data <=24'h380d64 ;//
	 329  :reg_data <=24'h380e02 ;// VTS 740
	 330  :reg_data <=24'h380fe4 ;//
	 331  :reg_data <=24'h381304 ;//        
	 332  :reg_data <=24'h361800 ;// 720p reference mode
	 333  :reg_data <=24'h361229 ;//
	 334  :reg_data <=24'h370952 ;//
	 335  :reg_data <=24'h370c03 ;//
	 336  :reg_data <=24'h3a0202 ;// AEC ceiling: one frame
	 337  :reg_data <=24'h3a03e0 ;//

	 338  :reg_data <=24'h3a0801 ;//
	 339  :reg_data <=24'h3a0950 ;//
	 340  :reg_data <=24'h3a0a01 ;//
	 341  :reg_data <=24'h3a0b18 ;//
	 342  :reg_data <=24'h3a0e03 ;//
	 343  :reg_data <=24'h3a0d04 ;//
	 344  :reg_data <=24'h3a1402 ;// AEC ceiling: one frame
	 345  :reg_data <=24'h3a15e0 ;//
	 346  :reg_data <=24'h400402 ;//
	 347  :reg_data <=24'h30021c ;//         
	 348  :reg_data <=24'h3006c3 ;//         
	 349  :reg_data <=24'h471303 ;//
	 350  :reg_data <=24'h440704 ;//         
	 351  :reg_data <=24'h460b37 ;//           
     352  :reg_data <=24'h460c20 ;//          
	 353  :reg_data <=24'h483716 ;//         
	 354  :reg_data <=24'h382404 ;//         
	 355  :reg_data <=24'h500183 ;//         
	 356  :reg_data <=24'h3a0078 ;// disable night-mode frame-rate reduction
	 357  :reg_data <=24'h350303 ;// manual exposure and manual sensor gain
	 358  :reg_data <={16'h3500, 4'b0000, FIXED_EXPOSURE_REG[19:16]};
	 359  :reg_data <={16'h3501, FIXED_EXPOSURE_REG[15:8]};
	 360  :reg_data <={16'h3502, FIXED_EXPOSURE_REG[7:0]};
	 361  :reg_data <={16'h350a, 6'b000000, FIXED_SENSOR_GAIN_X16[9:8]};
	 362  :reg_data <={16'h350b, FIXED_SENSOR_GAIN_X16[7:0]};
	 363  :reg_data <={16'h3400, 4'b0000, FIXED_WB_R[11:8]};
	 364  :reg_data <={16'h3401, FIXED_WB_R[7:0]};
	 365  :reg_data <={16'h3402, 4'b0000, FIXED_WB_G[11:8]};
	 366  :reg_data <={16'h3403, FIXED_WB_G[7:0]};
	 367  :reg_data <={16'h3404, 4'b0000, FIXED_WB_B[11:8]};
	 368  :reg_data <={16'h3405, FIXED_WB_B[7:0]};
	 369  :reg_data <=24'h340600 ;// automatic white balance; never tied to KEY2
	 370  :reg_data <=24'h300802 ;// restart streaming after all fixed settings
	 default:reg_data<=24'hffffff;//        
    endcase      
end	 



endmodule
