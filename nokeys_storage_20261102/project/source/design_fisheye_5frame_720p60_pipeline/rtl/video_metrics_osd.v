`timescale 1ns/1ps

// Compact reference OSD plus the KEY1 enhancement-enable state.
// RGB remains combinational to preserve top-level RGB/DE registration.
module video_metrics_osd #(
    // Display-only control: the source-frame marker remains available to PC tracking.
    parameter LATENCY_OVERLAY_ENABLE = 1,
    parameter CORRECTION_FIRST_ONLY = 0,
    parameter MINIMUM_PIXEL_MODE = 0
) (
    input wire first_latency_enable_i,
    input wire [16:0] minimum_us_i,
    input wire minimum_valid_i,
    input wire [6:0] minimum_layout_i,
    input wire panorama_marker_i,
    input wire pixel_clk,
    input wire reset_n,
    input wire vsync,
    input wire de_in,
    input wire [15:0] rgb_in,
    input wire [13:0] latency_tenth_ms,
    input wire latency_valid,
    input wire [55:0] pane_first_tenths_i,pane_end_tenths_i,
    input wire [3:0] pane_first_valid_i,pane_end_valid_i,
    input wire [6:0] pane_layout_i,
    input wire [11:0] output_refresh_tenths,
    input wire output_refresh_valid,
    input wire [1:0] display_mode_async,
    input wire [2:0] view_i,
    input wire enhancement_enable,sharpen_enable,stabilized_async,
    input wire [31:0] source_frame_async,source_tick_async,
    input wire [47:0] attitude_async,input wire attitude_toggle_async,attitude_enabled_async,
    output wire [15:0] rgb_out
);
    reg [11:0] x_pos,y_pos;
    reg de_d,vs_d;
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin
            x_pos<=0;y_pos<=0;de_d<=0;vs_d<=0;
        end else begin
            de_d<=de_in;vs_d<=vsync;
            if(vsync&&!vs_d) begin x_pos<=0;y_pos<=0;end
            else if(de_in) x_pos<=de_d ? x_pos+1'b1 : 12'd1;
            else if(de_d) begin x_pos<=0;y_pos<=y_pos+1'b1;end
        end
    end
    reg [1:0] mode_meta,mode_sync,show_mode;
    // The bank-associated bundle changes only in vertical blanking. Two
    // settling stages followed by a VSYNC-only latch keep one marker per frame.
    reg [63:0] source_meta,source_sync;
    reg [79:0] marker_header;
    reg [95:0] marker_bits;
    reg [7:0] marker_crc;
    reg [3:0] marker_step;
    reg marker_busy,marker_valid;
    function [7:0] crc_byte;
        input [7:0] previous,value;
        reg [7:0] c;
        integer j;
        begin
            c=previous^value;
            for(j=0;j<8;j=j+1)c=c[7]?(c<<1)^8'h07:c<<1;
            crc_byte=c;
        end
    endfunction
    wire [7:0] next_marker_crc=crc_byte(marker_crc,marker_header[marker_step*8+:8]);
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n)begin
            source_meta<=0;source_sync<=0;marker_header<=0;marker_bits<=0;
            marker_crc<=0;marker_step<=0;marker_busy<=0;marker_valid<=0;
        end else begin
            source_meta<={source_tick_async,source_frame_async};source_sync<=source_meta;
            if(vsync && marker_header!={source_sync,16'h01a5})begin
                marker_header<={source_sync,16'h01a5};marker_step<=0;
                marker_crc<=0;marker_busy<=1;marker_valid<=0;
            end else if(marker_busy)begin
                marker_crc<=next_marker_crc;marker_step<=marker_step+1'b1;
                if(marker_step==9)begin
                    marker_bits<={~next_marker_crc,next_marker_crc,marker_header};
                    marker_busy<=0;marker_valid<=1;
                end
            end
        end
    end
    reg show_enhancement,show_stabilized,stabilized_meta,stabilized_sync;
    reg [2:0] view_meta,view_sync,show_view;
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin show_stabilized<=0;stabilized_meta<=0;stabilized_sync<=0;mode_meta<=0;mode_sync<=0;show_mode<=0;show_enhancement<=1;view_meta<=0;view_sync<=0;show_view<=0;end
        else begin
            stabilized_meta<=stabilized_async;stabilized_sync<=stabilized_meta;
            mode_meta<=display_mode_async;mode_sync<=mode_meta;
            view_meta<=view_i;view_sync<=view_meta;
            if(vsync) begin show_mode<=mode_sync;show_enhancement<=enhancement_enable;show_stabilized<=stabilized_sync;show_view<=view_sync;end
        end
    end
    function [15:0] bcd_step;
        input [15:0] old_bcd;
        input bit_in;
        reg [15:0] adjusted;
        integer k;
        begin
            adjusted=old_bcd;
            for(k=0;k<4;k=k+1)
                if(adjusted[k*4+:4]>=5) adjusted[k*4+:4]=adjusted[k*4+:4]+4'd3;
            bcd_step={adjusted[14:0],bit_in};
        end
    endfunction
    // Stable UART angle bundle: sample after a three-clock toggle synchronizer.
    // Convert/latch in vertical blanking; no RGB pipeline stage is introduced.
    reg [2:0] angle_toggle_sync,angle_enable_sync;
    reg angle_seen,angle_have,angle_show;
    reg [47:0] angle_shadow,angle_shift,angle_bcd;
    reg [15:0] angle_bcd_work;reg [11:0] angle_magnitude;
    reg [2:0] angle_sign;reg [1:0] angle_axis;reg [3:0] angle_step;
    reg angle_converting;reg [5:0] angle_age;
    wire [15:0] angle_word=angle_shift[15:0];
    always @(posedge pixel_clk or negedge reset_n)begin
      if(!reset_n)begin
        angle_toggle_sync<=0;angle_enable_sync<=0;angle_seen<=0;angle_have<=0;angle_show<=0;
        angle_shadow<=0;angle_shift<=0;angle_bcd<=0;angle_bcd_work<=0;angle_magnitude<=0;
        angle_sign<=0;angle_axis<=0;angle_step<=0;angle_converting<=0;angle_age<=63;
      end else begin
        angle_toggle_sync<={angle_toggle_sync[1:0],attitude_toggle_async};
        angle_enable_sync<={angle_enable_sync[1:0],attitude_enabled_async===1'b1};
        if(angle_toggle_sync[2]!=angle_seen)begin angle_shadow<=attitude_async;angle_seen<=angle_toggle_sync[2];angle_have<=1;angle_age<=0;end
        if(vsync&&!vs_d)begin
          if(angle_age<63)angle_age<=angle_age+1'b1;
          angle_show<=angle_enable_sync[2]&&angle_have&&angle_age<30;
          angle_shift<=angle_shadow;angle_axis<=0;angle_step<=0;angle_bcd_work<=0;angle_converting<=1;
        end else if(angle_converting)begin
          if(angle_step==0)begin
            angle_sign[angle_axis]<=angle_word[15];
            angle_magnitude<=angle_word[15]?(~angle_word[11:0]+1'b1):angle_word[11:0];
            angle_bcd_work<=0;angle_step<=1;
          end else if(angle_step==12)begin
            angle_bcd[angle_axis*16+:16]<=bcd_step(angle_bcd_work,angle_magnitude[0]);
            angle_shift<=angle_shift>>16;angle_axis<=angle_axis+1'b1;angle_step<=0;
            if(angle_axis==2)angle_converting<=0;
          end else begin angle_bcd_work<=bcd_step(angle_bcd_work,angle_magnitude[12-angle_step]);angle_step<=angle_step+1'b1;end
        end
      end
    end
    reg [111:0] pane_shift;
    reg [127:0] pane_bcd;
    reg [15:0] pane_convert_bcd;
    reg [3:0] pane_step;
    reg [2:0] pane_number;
    reg pane_converting;
    reg [3:0] show_pane_first,show_pane_end;
    reg [6:0] show_pane_layout;
    always @(posedge pixel_clk or negedge reset_n)begin
        if(!reset_n)begin
            pane_shift<=0;pane_bcd<=0;pane_convert_bcd<=0;pane_step<=0;
            pane_number<=0;pane_converting<=0;show_pane_first<=0;show_pane_end<=0;show_pane_layout<=0;
        end else if(vsync&&!vs_d)begin
            pane_shift<={pane_end_tenths_i,pane_first_tenths_i};pane_bcd<=0;
            pane_convert_bcd<=0;pane_step<=0;pane_number<=0;pane_converting<=1;
            show_pane_first<=pane_first_valid_i;show_pane_end<=pane_end_valid_i;show_pane_layout<=pane_layout_i;
        end else if(pane_converting)begin
            if(pane_step==13)begin
                pane_bcd[pane_number*16+:16]<=bcd_step(pane_convert_bcd,pane_shift[0]);
                pane_shift<=pane_shift>>14;pane_convert_bcd<=0;pane_step<=0;
                pane_number<=pane_number+1'b1;
                if(pane_number==7)pane_converting<=0;
            end else begin
                pane_convert_bcd<=bcd_step(pane_convert_bcd,pane_shift[13-pane_step]);
                pane_step<=pane_step+1'b1;
            end
        end
    end

    function [34:0] glyph;
        input [7:0] ch;
        begin
            case (ch)
                "0": glyph = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1": glyph = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2": glyph = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3": glyph = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4": glyph = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6": glyph = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7": glyph = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8": glyph = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9": glyph = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                "u": glyph = {5'b00000,5'b00000,5'b10001,5'b10001,5'b10001,5'b10011,5'b01101};
                "l": glyph = {5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "a": glyph = {5'b00000,5'b00000,5'b01110,5'b00001,5'b01111,5'b10001,5'b01111};
                "t": glyph = {5'b00100,5'b00100,5'b11111,5'b00100,5'b00100,5'b00101,5'b00010};
                "e": glyph = {5'b00000,5'b00000,5'b01110,5'b10001,5'b11111,5'b10000,5'b01110};
                "n": glyph = {5'b00000,5'b00000,5'b11110,5'b10001,5'b10001,5'b10001,5'b10001};
                "c": glyph = {5'b00000,5'b00000,5'b01111,5'b10000,5'b10000,5'b10000,5'b01111};
                "y": glyph = {5'b00000,5'b00000,5'b10001,5'b10001,5'b01111,5'b00001,5'b01110};
                "m": glyph = {5'b00000,5'b00000,5'b11010,5'b10101,5'b10101,5'b10101,5'b10101};
                "s": glyph = {5'b00000,5'b00000,5'b01111,5'b10000,5'b01110,5'b00001,5'b11110};
                "I": glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                "G": glyph = {5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
                "O": glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "L": glyph = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "A": glyph = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "T": glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "F": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "P": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "S": glyph = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "M": glyph = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "C": glyph = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "R": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "W": glyph = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "E": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "N": glyph = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                "Q": glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
                "U": glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "D": glyph = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "H": glyph = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "Z": glyph = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
                "Y": glyph = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                "B": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                ".": glyph = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b01100,5'b01100};
                "-": glyph = {5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
                "+": glyph = {5'b00000,5'b00100,5'b00100,5'b11111,5'b00100,5'b00100,5'b00000};
                default: glyph = 35'd0;
            endcase
        end
    endfunction

    // The first-pixel meter publishes a coherent value/layout after the real
    // content event. Wait for this scan's invalid->valid transition: a repeat,
    // mode switch, or failed scan must not display a previous frame's number.
    reg [1:0] first_enable_sync;
    reg first_seen_invalid,first_converting,first_number_ready;
    reg [13:0] first_binary;
    reg [15:0] first_bcd_work;
    reg [19:0] first_digits;
    reg [3:0] first_step;
    wire first_eligible=CORRECTION_FIRST_ONLY&&first_enable_sync[1]&&
        show_mode!=0&&!show_enhancement&&!show_stabilized;
    wire first_lane=show_mode==2;
    wire first_measurement_valid=pane_first_valid_i[first_lane]&&
        pane_layout_i==={show_mode,show_view,show_stabilized,show_enhancement};
    function [19:0] bcd_step5;
        input [19:0] old_bcd;input bit_in;
        reg [19:0] adjusted;integer k;
        begin
            adjusted=old_bcd;
            for(k=0;k<5;k=k+1)if(adjusted[k*4+:4]>=5)adjusted[k*4+:4]=adjusted[k*4+:4]+4'd3;
            bcd_step5={adjusted[18:0],bit_in};
        end
    endfunction
    generate if(MINIMUM_PIXEL_MODE)begin: minimum_display
        reg [16:0] binary_us;
        reg [19:0] work_bcd;
        reg [4:0] step;
        // The minimum for late pixels is known after the text has passed.
        // Latch the most recent completed scan at VSYNC, never mid-letter.
        always @(posedge pixel_clk or negedge reset_n)begin
            if(!reset_n)begin
                first_enable_sync<=0;first_seen_invalid<=0;first_converting<=0;
                first_number_ready<=0;first_binary<=0;first_bcd_work<=0;first_digits<=0;first_step<=0;
                binary_us<=0;work_bcd<=0;step<=0;
            end else begin
                first_enable_sync<={first_enable_sync[0],first_latency_enable_i===1'b1};
                if(vsync&&!vs_d)begin
                    first_number_ready<=0;first_converting<=0;
                    if(minimum_valid_i&&minimum_layout_i==={mode_sync,view_sync,1'b0,1'b0}&&
                       mode_sync!=0&&first_enable_sync[1]&&!enhancement_enable&&!stabilized_sync)begin
                        binary_us<=minimum_us_i;work_bcd<=0;step<=0;first_converting<=1;
                    end
                end else if(first_converting)begin
                    work_bcd<=bcd_step5(work_bcd,binary_us[16-step]);
                    if(step==16)begin
                        first_digits<=bcd_step5(work_bcd,binary_us[0]);
                        first_number_ready<=1;first_converting<=0;
                    end else step<=step+1'b1;
                end
                if(!first_enable_sync[1]||enhancement_enable||stabilized_sync)begin first_number_ready<=0;first_converting<=0;end
            end
        end
    end else begin: first_display
    always @(posedge pixel_clk or negedge reset_n)begin
        if(!reset_n)begin
            first_enable_sync<=0;first_seen_invalid<=0;first_converting<=0;
            first_number_ready<=0;first_binary<=0;first_bcd_work<=0;first_digits<=0;first_step<=0;
        end else begin
            first_enable_sync<={first_enable_sync[0],first_latency_enable_i===1'b1};
            if(vsync&&!vs_d)begin
                first_seen_invalid<=0;first_converting<=0;first_number_ready<=0;
            end else if(!first_eligible||!first_measurement_valid)begin
                first_seen_invalid<=1;first_converting<=0;first_number_ready<=0;
            end else if(first_seen_invalid&&!first_number_ready&&!first_converting)begin
                first_binary<=pane_first_tenths_i[first_lane*14+:14];
                first_bcd_work<=0;first_step<=0;first_converting<=1;
            end else if(first_converting)begin
                first_bcd_work<=bcd_step(first_bcd_work,first_binary[13-first_step]);
                if(first_step==13)begin
                    first_digits<=bcd_step(first_bcd_work,first_binary[0]);
                    first_number_ready<=1;first_converting<=0;
                end else first_step<=first_step+1'b1;
            end
        end
    end
    end endgenerate
    wire [11:0] first_x0=show_mode==2 ? 12'd648 :
        show_mode==1&&show_view!=5 ? 12'd328 : 12'd8;
    wire [11:0] first_y0=show_mode==2||(show_mode==1&&show_view!=5) ? 12'd188 : 12'd8;
    wire first_area=de_in&&first_eligible&&x_pos>=first_x0&&x_pos<first_x0+368&&
        y_pos>=first_y0&&y_pos<first_y0+36;
    reg [7:0] first_character;
    reg [34:0] first_glyph;
    reg [4:0] first_column;
    reg [4:0] first_offset;
    integer first_char_scan;
    always @*begin
        first_column=31;first_offset=31;
        for(first_char_scan=0;first_char_scan<15;first_char_scan=first_char_scan+1)
            if(x_pos>=first_x0+4+first_char_scan*24&&x_pos<first_x0+4+(first_char_scan+1)*24)begin
                first_column=first_char_scan;first_offset=x_pos-first_x0-4-first_char_scan*24;
            end
        first_character=" ";
        case(first_column)
            0:first_character="l";1:first_character="a";2:first_character="t";
            3:first_character="e";4:first_character="n";5:first_character="c";6:first_character="y";
            8:first_character=first_number_ready?(first_digits[15:12]==0?" ":8'h30+first_digits[15:12]):"-";
            9:first_character=first_number_ready?(first_digits[15:8]==0?" ":8'h30+first_digits[11:8]):"-";
            10:first_character=first_number_ready?8'h30+first_digits[7:4]:"-";
            11:first_character=".";
            12:first_character=first_number_ready?8'h30+first_digits[3:0]:"-";
            13:first_character="m";14:first_character="s";
            default:first_character=" ";
        endcase
        if(MINIMUM_PIXEL_MODE)begin
            case(first_column)
                8:first_character=first_number_ready?(first_digits[19:16]==0?" ":8'h30+first_digits[19:16]):"-";
                9:first_character=first_number_ready?(first_digits[19:12]==0?" ":8'h30+first_digits[15:12]):"-";
                10:first_character=first_number_ready?(first_digits[19:8]==0?" ":8'h30+first_digits[11:8]):"-";
                11:first_character=first_number_ready?8'h30+first_digits[7:4]:"-";
                12:first_character=first_number_ready?8'h30+first_digits[3:0]:"-";
                13:first_character="u";14:first_character="s";
            endcase
        end
        first_glyph=glyph(first_character);
    end
    // Four screen pixels per font dot, with a four-pixel solid-black border.
    // This changes only the overlay; RGB/DE retain their existing registration.
    wire first_pixel=first_offset<20&&y_pos>=first_y0+4&&y_pos<first_y0+32 ?
        first_glyph[34-((y_pos-first_y0-4)>>2)*5-(first_offset>>2)]:1'b0;

    reg [1:0] pane_index;
    reg [11:0] pane_x0,pane_y0,pane_dx,pane_dy;
    reg pane_area,pane_end_line,pane_number_valid,pane_glyph_pixel;
    reg [15:0] pane_digits;
    reg [7:0] pane_character;
    reg [34:0] pane_glyph;
    reg [3:0] pane_char;
    reg [2:0] pane_font_x,pane_font_y;
    reg [4:0] pane_column;
    integer pane_char_scan;
    always @* begin
        pane_index=0;pane_x0=12'd8;pane_y0=12'd8;
        if(show_mode==2)begin
            pane_index=x_pos>=640?1:0;
            pane_x0=x_pos>=640?12'd648:12'd8;pane_y0=12'd548;
        end else if(show_mode==1 && show_view==5)begin
            pane_index={y_pos>=360,x_pos>=640};
            pane_x0=x_pos>=640?12'd648:12'd8;
            pane_y0=y_pos>=360?12'd368:12'd8;
        end
        pane_dx=x_pos-pane_x0;pane_dy=y_pos-pane_y0;
        pane_area=de_in && (show_mode==0 || (show_mode==3 && (show_view==7 || show_view==6)) || (show_mode==2 && (pane_index==0 || show_view==6))) && (show_pane_layout==={show_mode,show_view,show_stabilized,show_enhancement}) &&
            x_pos>=pane_x0 && x_pos<pane_x0+168 && y_pos>=pane_y0 && y_pos<pane_y0+36;
        pane_end_line=pane_dy>=18;
        pane_digits=pane_end_line?pane_bcd[(pane_index+4)*16+:16]:pane_bcd[pane_index*16+:16];
        pane_number_valid=pane_end_line?show_pane_end[pane_index]:show_pane_first[pane_index];
        pane_char=15;pane_column=31;
        for(pane_char_scan=0;pane_char_scan<14;pane_char_scan=pane_char_scan+1)
            if(pane_dx>=pane_char_scan*12 && pane_dx<(pane_char_scan+1)*12)begin
                pane_char=pane_char_scan;pane_column=pane_dx-pane_char_scan*12;
            end
        pane_font_x=pane_column>>1;
        pane_font_y=(pane_end_line?pane_dy-18:pane_dy)>>1;
        pane_character=" ";
        case(pane_char)
            0:pane_character=pane_end_line?"E":show_mode==0||(show_mode==2&&pane_index==0)?"R":show_view==7?"B":"C";
            1:pane_character=pane_end_line?"N":show_mode==0||(show_mode==2&&pane_index==0)?"A":show_view==7?"A":"T";
            2:pane_character=pane_end_line?"D":show_mode==0||(show_mode==2&&pane_index==0)?"W":show_view==7?"S":"R";
            4:pane_character=pane_end_line?" ":"F";
            6:pane_character=pane_number_valid?(pane_digits[15:12]==0?" ":8'h30+pane_digits[15:12]):"-";
            7:pane_character=pane_number_valid?8'h30+pane_digits[11:8]:"-";
            8:pane_character=pane_number_valid?8'h30+pane_digits[7:4]:"-";
            9:pane_character=".";
            10:pane_character=pane_number_valid?8'h30+pane_digits[3:0]:"-";
            11:pane_character="M";
            12:pane_character="S";
            default:pane_character=" ";
        endcase
        pane_glyph=glyph(pane_character);
        pane_glyph_pixel=pane_font_x<5 && pane_font_y<7 ?
            pane_glyph[34-pane_font_y*5-pane_font_x]:1'b0;
    end
    wire split_border=de_in && show_mode==2 && y_pos>=180 && y_pos<540 && (x_pos==639 || x_pos==640);
    wire quad_divider=de_in&&show_mode==1&&show_view==5&&(x_pos==640||y_pos==360);
    wire [15:0] framed_rgb=quad_divider?16'h7bef:rgb_in;
    // Preserve the existing private source-frame marker used by PC tracking.
    reg [1:0] panorama_marker_sync;
    always @(posedge pixel_clk or negedge reset_n)begin
      if(!reset_n)panorama_marker_sync<=0;else panorama_marker_sync<={panorama_marker_sync[0],panorama_marker_i};
    end
    wire marker_area=de_in&&(show_mode==2||(show_mode==0&&panorama_marker_sync[1]===1'b1))&&marker_valid&&x_pos>=1088&&x_pos<1280&&y_pos<32;
    wire [6:0] marker_index=y_pos[4:3]*7'd24+((x_pos-12'd1088)>>3);
    wire angle_area=de_in&&angle_show&&x_pos>=8&&x_pos<368&&y_pos>=670&&y_pos<690;
    reg [7:0] angle_character;reg [34:0] angle_glyph;
    reg [4:0] angle_column;reg [3:0] angle_offset;reg [1:0] angle_slot;
    reg [3:0] angle_digit_column;reg [15:0] angle_digits;integer angle_scan;
    always @*begin
      angle_column=31;angle_offset=15;
      for(angle_scan=0;angle_scan<30;angle_scan=angle_scan+1)
        if(x_pos>=8+angle_scan*12&&x_pos<20+angle_scan*12)begin angle_column=angle_scan;angle_offset=x_pos-(8+angle_scan*12);end
      angle_slot=angle_column<10?0:angle_column<20?1:2;
      angle_digit_column=angle_column<10?angle_column:angle_column<20?angle_column-10:angle_column-20;
      angle_digits=angle_bcd[angle_slot*16+:16];angle_character=" ";
      case(angle_digit_column)
        0:angle_character=angle_slot==0?"R":angle_slot==1?"P":"Y";
        2:angle_character=angle_sign[angle_slot]?"-":"+";
        3:angle_character=8'h30+angle_digits[15:12];
        4:angle_character=8'h30+angle_digits[11:8];
        5:angle_character=8'h30+angle_digits[7:4];
        6:angle_character=".";
        7:angle_character=8'h30+angle_digits[3:0];
        default:angle_character=" ";
      endcase
      angle_glyph=glyph(angle_character);
    end
    wire angle_pixel=angle_offset<10&&y_pos>=672&&y_pos<686?angle_glyph[34-((y_pos-672)>>1)*5-(angle_offset>>1)]:1'b0;
    assign rgb_out=marker_area?(marker_bits[marker_index]?16'hffff:16'h0000):
        angle_area?(angle_pixel?16'hffff:16'h0842):
        first_area ? (first_pixel?16'hffff:16'h0000) :
        (LATENCY_OVERLAY_ENABLE && pane_area) ? (pane_glyph_pixel?16'hffff:16'h0842) :
        split_border?16'hffe0:framed_rgb;
endmodule
