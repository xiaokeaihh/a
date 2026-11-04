`timescale 1ns/1ps
module tb_bilinear_rgb565;
    reg clock = 1'b0;
    always #5 clock = ~clock;

    reg reset_n = 1'b0;
    reg pixel_valid_i = 1'b0;
    reg neighborhood_valid_i = 1'b0;
    reg [63:0] source_pixels_flat = 64'd0;
    reg [7:0] fractional_x = 8'd0;
    reg [7:0] fractional_y = 8'd0;
    wire pixel_valid_o;
    wire [15:0] corrected_pixel;

    bilinear_rgb565 dut (
        .clock(clock), .reset_n(reset_n),
        .pixel_valid_i(pixel_valid_i),
        .neighborhood_valid_i(neighborhood_valid_i),
        .source_pixels_flat(source_pixels_flat),
        .fractional_x(fractional_x), .fractional_y(fractional_y),
        .pixel_valid_o(pixel_valid_o), .corrected_pixel(corrected_pixel)
    );

    task send_and_check;
        input [7:0] fx;
        input [7:0] fy;
        input valid;
        input [15:0] expected;
        begin
            @(negedge clock);
            fractional_x = fx;
            fractional_y = fy;
            neighborhood_valid_i = valid;
            pixel_valid_i = 1'b1;
            @(negedge clock);
            pixel_valid_i = 1'b0;
            wait (pixel_valid_o);
            #1;
            if (corrected_pixel !== expected)
                $fatal(1, "bilinear mismatch: got %h expected %h", corrected_pixel, expected);
        end
    endtask

    initial begin
        repeat (3) @(negedge clock);
        reset_n = 1'b1;

        source_pixels_flat = {16'hffff, 16'h001f, 16'h07e0, 16'hf800};
        send_and_check(8'd0, 8'd0, 1'b1, 16'hf800);
        send_and_check(8'd128, 8'd128, 1'b1, 16'h8410);
        send_and_check(8'd128, 8'd128, 1'b0, 16'h0000);

        source_pixels_flat = {4{16'h1234}};
        send_and_check(8'd37, 8'd219, 1'b1, 16'h1234);

        $display("PASS tb_bilinear_rgb565");
        $finish;
    end
endmodule
