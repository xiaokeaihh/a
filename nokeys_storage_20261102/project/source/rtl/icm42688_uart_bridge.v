`timescale 1ns / 1ps

// ICM-42688-P, four-wire SPI mode 0.  The 27 MHz board clock is independent
// of the camera and DDR clock domains.  INT1 is synchronized before use.
module icm42688_uart_bridge #(
    parameter integer CLK_HZ       = 27000000,
    parameter integer UART_BAUD    = 115200,
    parameter integer SPI_HALF_DIV = 14
)(
    input  wire clk,
    input  wire rst_n,
    input  wire imu_miso,
    input  wire imu_int1,
    output wire imu_sclk,
    output wire imu_mosi,
    output wire imu_cs_n,
    output wire uart_tx
);
    localparam [3:0] S_BOOT       = 4'd0;
    localparam [3:0] S_ID_START   = 4'd1;
    localparam [3:0] S_ID_WAIT    = 4'd2;
    localparam [3:0] S_ID_CHECK   = 4'd3;
    localparam [3:0] S_CFG_START  = 4'd4;
    localparam [3:0] S_CFG_WAIT   = 4'd5;
    localparam [3:0] S_SETTLE     = 4'd6;
    localparam [3:0] S_WAIT_DRDY  = 4'd7;
    localparam [3:0] S_READ_START = 4'd8;
    localparam [3:0] S_READ_WAIT  = 4'd9;
    localparam [3:0] S_ID_RETRY   = 4'd10;

    localparam integer BOOT_CYCLES   = CLK_HZ / 50;  // 20 ms
    localparam integer SETTLE_CYCLES = CLK_HZ / 10;  // 100 ms
    localparam integer POLL_CYCLES   = CLK_HZ / 100; // INT1 fallback, 10 ms

    reg [3:0] state;
    reg [31:0] delay_count;
    reg [31:0] poll_count;
    reg [2:0] cfg_index;
    reg [2:0] report_divider;
    reg [7:0] who_am_i;
    reg imu_ok;
    reg report_strobe;

    reg [15:0] ax, ay, az, gx, gy, gz;

    reg op_start;
    reg op_read;
    reg [6:0] op_addr;
    reg [7:0] op_wdata;
    reg [3:0] op_length;
    wire op_done;
    wire op_rx_valid;
    wire [3:0] op_rx_index;
    wire [7:0] op_rx_data;

    reg int1_meta, int1_sync, int1_prev;
    wire int1_rise = int1_sync & ~int1_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int1_meta <= 1'b0;
            int1_sync <= 1'b0;
            int1_prev <= 1'b0;
        end else begin
            int1_meta <= imu_int1;
            int1_sync <= int1_meta;
            int1_prev <= int1_sync;
        end
    end

    icm42688_spi_transaction #(.HALF_DIV(SPI_HALF_DIV)) spi_if (
        .clk(clk), .rst_n(rst_n),
        .start(op_start), .read_en(op_read), .address(op_addr),
        .write_data(op_wdata), .read_length(op_length),
        .done(op_done), .rx_valid(op_rx_valid),
        .rx_index(op_rx_index), .rx_data(op_rx_data),
        .miso(imu_miso), .mosi(imu_mosi),
        .sclk(imu_sclk), .cs_n(imu_cs_n)
    );

    icm42688_uart_report #(.CLK_HZ(CLK_HZ), .UART_BAUD(UART_BAUD)) report (
        .clk(clk), .rst_n(rst_n), .strobe(report_strobe),
        .valid_id(imu_ok), .who_am_i(who_am_i),
        .ax(ax), .ay(ay), .az(az), .gx(gx), .gy(gy), .gz(gz),
        .uart_tx(uart_tx)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_BOOT;
            delay_count <= 32'd0;
            poll_count <= 32'd0;
            cfg_index <= 3'd0;
            report_divider <= 3'd0;
            who_am_i <= 8'h00;
            imu_ok <= 1'b0;
            report_strobe <= 1'b0;
            op_start <= 1'b0;
            op_read <= 1'b0;
            op_addr <= 7'd0;
            op_wdata <= 8'd0;
            op_length <= 4'd1;
            ax <= 16'd0;
            ay <= 16'd0;
            az <= 16'd0;
            gx <= 16'd0;
            gy <= 16'd0;
            gz <= 16'd0;
        end else begin
            op_start <= 1'b0;
            report_strobe <= 1'b0;
            case (state)
                S_BOOT: begin
                    if (delay_count == BOOT_CYCLES-1) begin
                        delay_count <= 32'd0;
                        state <= S_ID_START;
                    end else delay_count <= delay_count + 1'b1;
                end
                S_ID_START: begin
                    op_read <= 1'b1;
                    op_addr <= 7'h75;  // WHO_AM_I, expected 0x47
                    op_length <= 4'd1;
                    op_start <= 1'b1;
                    state <= S_ID_WAIT;
                end
                S_ID_WAIT: begin
                    if (op_rx_valid && op_rx_index == 4'd0)
                        who_am_i <= op_rx_data;
                    if (op_done) state <= S_ID_CHECK;
                end
                S_ID_CHECK: begin
                    if (who_am_i == 8'h47) begin
                        imu_ok <= 1'b1;
                        cfg_index <= 3'd0;
                        state <= S_CFG_START;
                    end else begin
                        imu_ok <= 1'b0;
                        report_strobe <= 1'b1; // ID=xx ERR on UART
                        delay_count <= 32'd0;
                        state <= S_ID_RETRY;
                    end
                end
                S_ID_RETRY: begin
                    if (delay_count == CLK_HZ-1) begin
                        delay_count <= 32'd0;
                        state <= S_ID_START;
                    end else delay_count <= delay_count + 1'b1;
                end
                S_CFG_START: begin
                    op_read <= 1'b0;
                    op_length <= 4'd1;
                    case (cfg_index)
                        3'd0: begin op_addr <= 7'h4f; op_wdata <= 8'h08; end // gyro 100 Hz, +/-2000 dps
                        3'd1: begin op_addr <= 7'h50; op_wdata <= 8'h08; end // accel 100 Hz, +/-16 g
                        3'd2: begin op_addr <= 7'h14; op_wdata <= 8'h03; end // INT1 pulse, push-pull, high
                        3'd3: begin op_addr <= 7'h64; op_wdata <= 8'h00; end // INT_ASYNC_RESET = 0
                        3'd4: begin op_addr <= 7'h65; op_wdata <= 8'h08; end // data ready on INT1
                        default: begin op_addr <= 7'h4e; op_wdata <= 8'h0f; end // gyro + accel LN
                    endcase
                    op_start <= 1'b1;
                    state <= S_CFG_WAIT;
                end
                S_CFG_WAIT: if (op_done) begin
                    if (cfg_index == 3'd5) begin
                        delay_count <= 32'd0;
                        state <= S_SETTLE;
                    end else begin
                        cfg_index <= cfg_index + 1'b1;
                        state <= S_CFG_START;
                    end
                end
                S_SETTLE: begin
                    if (delay_count == SETTLE_CYCLES-1) begin
                        delay_count <= 32'd0;
                        poll_count <= 32'd0;
                        state <= S_WAIT_DRDY;
                    end else delay_count <= delay_count + 1'b1;
                end
                S_WAIT_DRDY: begin
                    if (int1_rise || poll_count == POLL_CYCLES-1) begin
                        poll_count <= 32'd0;
                        state <= S_READ_START;
                    end else poll_count <= poll_count + 1'b1;
                end
                S_READ_START: begin
                    op_read <= 1'b1;
                    op_addr <= 7'h1f;  // ACCEL_DATA_X1 through GYRO_DATA_Z0
                    op_length <= 4'd12;
                    op_start <= 1'b1;
                    state <= S_READ_WAIT;
                end
                S_READ_WAIT: begin
                    if (op_rx_valid) begin
                        case (op_rx_index)
                            4'd0: ax[15:8] <= op_rx_data;
                            4'd1: ax[7:0] <= op_rx_data;
                            4'd2: ay[15:8] <= op_rx_data;
                            4'd3: ay[7:0] <= op_rx_data;
                            4'd4: az[15:8] <= op_rx_data;
                            4'd5: az[7:0] <= op_rx_data;
                            4'd6: gx[15:8] <= op_rx_data;
                            4'd7: gx[7:0] <= op_rx_data;
                            4'd8: gy[15:8] <= op_rx_data;
                            4'd9: gy[7:0] <= op_rx_data;
                            4'd10: gz[15:8] <= op_rx_data;
                            4'd11: gz[7:0] <= op_rx_data;
                        endcase
                    end
                    if (op_done) begin
                        if (report_divider == 3'd4) begin
                            report_divider <= 3'd0;
                            report_strobe <= 1'b1;
                        end else report_divider <= report_divider + 1'b1;
                        poll_count <= 32'd0;
                        state <= S_WAIT_DRDY;
                    end
                end
                default: state <= S_BOOT;
            endcase
        end
    end
endmodule

// One register write or a contiguous read of up to 15 bytes.
module icm42688_spi_transaction #(
    parameter integer HALF_DIV = 14
)(
    input wire clk, rst_n, start, read_en,
    input wire [6:0] address,
    input wire [7:0] write_data,
    input wire [3:0] read_length,
    output reg done, rx_valid,
    output reg [3:0] rx_index,
    output reg [7:0] rx_data,
    input wire miso,
    output wire mosi, sclk,
    output reg cs_n
);
    localparam [1:0] T_IDLE = 2'd0, T_ADDR = 2'd1,
                     T_WRITE = 2'd2, T_READ = 2'd3;
    reg [1:0] state;
    reg [3:0] count;
    reg [3:0] length_latched;
    reg read_latched;
    reg [7:0] data_latched;
    reg byte_start;
    reg [7:0] byte_tx;
    wire byte_done;
    wire [7:0] byte_rx;

    icm42688_spi_byte #(.HALF_DIV(HALF_DIV)) byte_engine (
        .clk(clk), .rst_n(rst_n), .start(byte_start),
        .tx_data(byte_tx), .rx_data(byte_rx), .done(byte_done),
        .miso(miso), .mosi(mosi), .sclk(sclk)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= T_IDLE;
            cs_n <= 1'b1;
            done <= 1'b0;
            rx_valid <= 1'b0;
            rx_index <= 4'd0;
            rx_data <= 8'd0;
            count <= 4'd0;
            length_latched <= 4'd1;
            read_latched <= 1'b0;
            data_latched <= 8'd0;
            byte_start <= 1'b0;
            byte_tx <= 8'd0;
        end else begin
            done <= 1'b0;
            rx_valid <= 1'b0;
            byte_start <= 1'b0;
            case (state)
                T_IDLE: if (start) begin
                    cs_n <= 1'b0;
                    read_latched <= read_en;
                    length_latched <= read_length;
                    data_latched <= write_data;
                    count <= 4'd0;
                    byte_tx <= {read_en, address};
                    byte_start <= 1'b1;
                    state <= T_ADDR;
                end
                T_ADDR: if (byte_done) begin
                    byte_tx <= read_latched ? 8'h00 : data_latched;
                    byte_start <= 1'b1;
                    state <= read_latched ? T_READ : T_WRITE;
                end
                T_WRITE: if (byte_done) begin
                    cs_n <= 1'b1;
                    done <= 1'b1;
                    state <= T_IDLE;
                end
                T_READ: if (byte_done) begin
                    rx_valid <= 1'b1;
                    rx_index <= count;
                    rx_data <= byte_rx;
                    if (count == length_latched-1'b1) begin
                        cs_n <= 1'b1;
                        done <= 1'b1;
                        state <= T_IDLE;
                    end else begin
                        count <= count + 1'b1;
                        byte_tx <= 8'h00;
                        byte_start <= 1'b1;
                    end
                end
                default: state <= T_IDLE;
            endcase
        end
    end
endmodule

module icm42688_spi_byte #(
    parameter integer HALF_DIV = 14
)(
    input wire clk, rst_n, start,
    input wire [7:0] tx_data,
    output reg [7:0] rx_data,
    output reg done,
    input wire miso,
    output reg mosi, sclk
);
    reg busy;
    reg [15:0] divider;
    reg [2:0] bit_index;
    reg [7:0] tx_latched, rx_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            divider <= 16'd0;
            bit_index <= 3'd7;
            tx_latched <= 8'd0;
            rx_shift <= 8'd0;
            rx_data <= 8'd0;
            mosi <= 1'b0;
            sclk <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                sclk <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    divider <= 16'd0;
                    bit_index <= 3'd7;
                    tx_latched <= tx_data;
                    rx_shift <= 8'd0;
                    mosi <= tx_data[7];
                end
            end else if (divider == HALF_DIV-1) begin
                divider <= 16'd0;
                if (!sclk) begin
                    sclk <= 1'b1;
                    rx_shift <= {rx_shift[6:0], miso};
                end else begin
                    sclk <= 1'b0;
                    if (bit_index == 3'd0) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        rx_data <= rx_shift;
                    end else begin
                        bit_index <= bit_index - 1'b1;
                        mosi <= tx_latched[bit_index-1'b1];
                    end
                end
            end else divider <= divider + 1'b1;
        end
    end
endmodule

// ASCII at 115200 8N1: ID=47 AX=hhhh AY=hhhh AZ=hhhh GX=hhhh GY=hhhh GZ=hhhh\r\n
// Values are signed 16-bit two's-complement raw samples in hexadecimal.
module icm42688_uart_report #(
    parameter integer CLK_HZ = 27000000,
    parameter integer UART_BAUD = 115200
)(
    input wire clk, rst_n, strobe, valid_id,
    input wire [7:0] who_am_i,
    input wire [15:0] ax, ay, az, gx, gy, gz,
    output wire uart_tx
);
    reg sending, error_mode;
    reg [5:0] char_index;
    reg [7:0] id_latched;
    reg [15:0] ax_l, ay_l, az_l, gx_l, gy_l, gz_l;
    reg [7:0] tx_byte;
    reg tx_start;
    wire tx_busy;
    reg [7:0] next_char;

    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            hex_char = (nibble < 4'd10) ? (8'h30 + {4'd0, nibble})
                                         : (8'h41 + {4'd0, nibble} - 8'd10);
        end
    endfunction

    always @* begin
        next_char = 8'h20;
        case (char_index)
            6'd0: next_char = "I";
            6'd1: next_char = "D";
            6'd2: next_char = "=";
            6'd3: next_char = hex_char(id_latched[7:4]);
            6'd4: next_char = hex_char(id_latched[3:0]);
            6'd5: next_char = " ";
            6'd6: next_char = error_mode ? "E" : "A";
            6'd7: next_char = error_mode ? "R" : "X";
            6'd8: next_char = error_mode ? "R" : "=";
            6'd9: next_char = error_mode ? 8'h0d : hex_char(ax_l[15:12]);
            6'd10: next_char = error_mode ? 8'h0a : hex_char(ax_l[11:8]);
            6'd11: next_char = hex_char(ax_l[7:4]);
            6'd12: next_char = hex_char(ax_l[3:0]);
            6'd14: next_char = "A";
            6'd15: next_char = "Y";
            6'd16: next_char = "=";
            6'd17: next_char = hex_char(ay_l[15:12]);
            6'd18: next_char = hex_char(ay_l[11:8]);
            6'd19: next_char = hex_char(ay_l[7:4]);
            6'd20: next_char = hex_char(ay_l[3:0]);
            6'd22: next_char = "A";
            6'd23: next_char = "Z";
            6'd24: next_char = "=";
            6'd25: next_char = hex_char(az_l[15:12]);
            6'd26: next_char = hex_char(az_l[11:8]);
            6'd27: next_char = hex_char(az_l[7:4]);
            6'd28: next_char = hex_char(az_l[3:0]);
            6'd30: next_char = "G";
            6'd31: next_char = "X";
            6'd32: next_char = "=";
            6'd33: next_char = hex_char(gx_l[15:12]);
            6'd34: next_char = hex_char(gx_l[11:8]);
            6'd35: next_char = hex_char(gx_l[7:4]);
            6'd36: next_char = hex_char(gx_l[3:0]);
            6'd38: next_char = "G";
            6'd39: next_char = "Y";
            6'd40: next_char = "=";
            6'd41: next_char = hex_char(gy_l[15:12]);
            6'd42: next_char = hex_char(gy_l[11:8]);
            6'd43: next_char = hex_char(gy_l[7:4]);
            6'd44: next_char = hex_char(gy_l[3:0]);
            6'd46: next_char = "G";
            6'd47: next_char = "Z";
            6'd48: next_char = "=";
            6'd49: next_char = hex_char(gz_l[15:12]);
            6'd50: next_char = hex_char(gz_l[11:8]);
            6'd51: next_char = hex_char(gz_l[7:4]);
            6'd52: next_char = hex_char(gz_l[3:0]);
            6'd53: next_char = 8'h0d;
            6'd54: next_char = 8'h0a;
            default: next_char = " ";
        endcase
    end

    icm42688_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(UART_BAUD)) tx (
        .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_byte),
        .busy(tx_busy), .tx(uart_tx)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sending <= 1'b0;
            error_mode <= 1'b0;
            char_index <= 6'd0;
            id_latched <= 8'd0;
            ax_l <= 16'd0; ay_l <= 16'd0; az_l <= 16'd0;
            gx_l <= 16'd0; gy_l <= 16'd0; gz_l <= 16'd0;
            tx_byte <= 8'd0;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            if (strobe && !sending && !tx_busy) begin
                error_mode <= ~valid_id;
                id_latched <= who_am_i;
                ax_l <= ax; ay_l <= ay; az_l <= az;
                gx_l <= gx; gy_l <= gy; gz_l <= gz;
                char_index <= 6'd0;
                sending <= 1'b1;
            end else if (sending && !tx_busy && !tx_start) begin
                tx_byte <= next_char;
                tx_start <= 1'b1;
                if (char_index == (error_mode ? 6'd10 : 6'd54))
                    sending <= 1'b0;
                else char_index <= char_index + 1'b1;
            end
        end
    end
endmodule

module icm42688_uart_tx #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD = 115200
)(
    input wire clk, rst_n, start,
    input wire [7:0] data,
    output reg busy,
    output reg tx
);
    localparam integer BAUD_DIV = (CLK_HZ + BAUD/2) / BAUD;
    localparam [1:0] U_IDLE=2'd0, U_START=2'd1,
                     U_DATA=2'd2, U_STOP=2'd3;
    reg [1:0] state;
    reg [15:0] divider;
    reg [2:0] bit_index;
    reg [7:0] data_latched;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= U_IDLE;
            divider <= 16'd0;
            bit_index <= 3'd0;
            data_latched <= 8'd0;
            busy <= 1'b0;
            tx <= 1'b1;
        end else begin
            case (state)
                U_IDLE: if (start) begin
                    busy <= 1'b1;
                    tx <= 1'b0;
                    divider <= 16'd0;
                    data_latched <= data;
                    state <= U_START;
                end
                U_START: if (divider == BAUD_DIV-1) begin
                    divider <= 16'd0;
                    bit_index <= 3'd0;
                    tx <= data_latched[0];
                    state <= U_DATA;
                end else divider <= divider + 1'b1;
                U_DATA: if (divider == BAUD_DIV-1) begin
                    divider <= 16'd0;
                    if (bit_index == 3'd7) begin
                        tx <= 1'b1;
                        state <= U_STOP;
                    end else begin
                        bit_index <= bit_index + 1'b1;
                        tx <= data_latched[bit_index+1'b1];
                    end
                end else divider <= divider + 1'b1;
                U_STOP: if (divider == BAUD_DIV-1) begin
                    divider <= 16'd0;
                    busy <= 1'b0;
                    tx <= 1'b1;
                    state <= U_IDLE;
                end else divider <= divider + 1'b1;
                default: state <= U_IDLE;
            endcase
        end
    end
endmodule
