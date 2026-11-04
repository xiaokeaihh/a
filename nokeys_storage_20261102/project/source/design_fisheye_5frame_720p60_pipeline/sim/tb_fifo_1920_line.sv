`timescale 1ns/1ps
module tb_fifo_1920_line;
    reg cam_clk=0, ddr_clk=0, rstn=0, vsync=0, en=0;
    reg [15:0] pixel=0;
    always #5 cam_clk=~cam_clk;
    always #4 ddr_clk=~ddr_clk;
    wire req, frame_start, frame_complete;
    wire [27:0] addr;
    wire [31:0] len;
    wire [255:0] data;
    reg data_req=0, done=0;
    wr_buf #(.H_NUM(1920), .V_NUM(1), .PIX_WIDTH(16)) dut (
        .ddr_clk(ddr_clk), .ddr_rstn(rstn), .wr_clk(cam_clk),
        .wr_fsync(vsync), .wr_en(en), .wr_data(pixel),
        .rd_bac(1'b0), .ddr_wreq(req), .ddr_waddr(addr),
        .ddr_wr_len(len), .ddr_wrdy(1'b1), .ddr_wdone(done),
        .ddr_wdata(data), .ddr_wdata_req(data_req),
        .write_bank(2'd0), .frame_start(frame_start),
        .frame_wirq(frame_complete)
    );
    integer i,j,beat=0,completes=0;
    always @(posedge ddr_clk) begin
        data_req <= 0;
        done <= 0;
        if (req) begin
            if (len != 120 || addr != 0) $fatal(1,"DDR command");
            data_req <= 1;
        end
        if (data_req) begin
            for (j=0;j<16;j=j+1)
                if (data[j*16 +:16] !== (beat*16+j))
                    $fatal(1,"beat %0d pixel %0d got %h",beat,j,data[j*16 +:16]);
            beat=beat+1;
            if (beat < 120) data_req <= 1;
            else done <= 1;
        end
        if (frame_complete) completes=completes+1;
    end
    task pulse_vsync;
        begin
            @(negedge cam_clk); vsync=1;
            @(negedge cam_clk); vsync=0;
        end
    endtask
    initial begin
        repeat(8) @(negedge cam_clk); rstn=1;
        repeat(8) @(negedge cam_clk); pulse_vsync();
        repeat(20) @(negedge cam_clk);
        for (i=0;i<1920;i=i+1) begin
            @(negedge cam_clk); en=1; pixel=i;
        end
        @(negedge cam_clk); en=0;
        repeat(400) @(negedge cam_clk);
        if (beat != 120) $fatal(1,"only %0d/120 beats",beat);
        pulse_vsync();
        repeat(20) @(negedge cam_clk);
        if (completes != 1) $fatal(1,"frame not published");
        $display("PASS: complete 1920-pixel line, 120 DDR beats");
        $finish;
    end
endmodule
