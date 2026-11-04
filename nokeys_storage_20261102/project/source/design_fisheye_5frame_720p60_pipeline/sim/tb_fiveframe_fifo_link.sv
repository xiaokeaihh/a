`timescale 1ns/1ps
module tb_fiveframe_fifo_link;
    reg cam_clk=0, ddr_clk=0, pix_clk=0, rstn=0;
    always #5 cam_clk=~cam_clk;
    always #4 ddr_clk=~ddr_clk;
    always #7 pix_clk=~pix_clk;

    reg cam_fsync=0, cam_en=0;
    reg [15:0] cam_pixel=0;
    wire wr_req, frame_start, frame_complete;
    wire [27:0] wr_addr;
    wire [31:0] wr_len;
    wire [255:0] wr_data;
    reg wr_data_req=0, wr_done=0;
    wr_buf #(.H_NUM(16), .V_NUM(2), .PIX_WIDTH(16)) raw (
        .ddr_clk(ddr_clk), .ddr_rstn(rstn), .wr_clk(cam_clk),
        .wr_fsync(cam_fsync), .wr_en(cam_en), .wr_data(cam_pixel),
        .rd_bac(1'b0), .ddr_wreq(wr_req), .ddr_waddr(wr_addr),
        .ddr_wr_len(wr_len), .ddr_wrdy(1'b1), .ddr_wdone(wr_done),
        .ddr_wdata(wr_data), .ddr_wdata_req(wr_data_req),
        .write_bank(2'd0), .frame_start(frame_start),
        .frame_wirq(frame_complete)
    );

    integer sent_lines=0, accepted_lines=0, complete_count=0;
    integer i, k;
    reg [255:0] expected;
    always @(posedge ddr_clk) begin
        wr_data_req <= 0;
        wr_done <= 0;
        if (wr_req) begin
            if (wr_len !== 1) $fatal(1,"wrong line length");
            if (wr_addr !== sent_lines*8) $fatal(1,"wrong DDR address %h",wr_addr);
            wr_data_req <= 1;
        end
        if (wr_data_req) begin
            for (k=0;k<16;k=k+1)
                expected[k*16 +: 16] = sent_lines*16+k;
            if (wr_data !== expected)
                $fatal(1,"raw line %0d differs: got %h expected %h",sent_lines,wr_data,expected);
            sent_lines=sent_lines+1;
            wr_done <= 1;
        end
        if (wr_done) accepted_lines=accepted_lines+1;
        if (frame_complete) complete_count=complete_count+1;
    end

    task camera_vsync;
        begin
            @(negedge cam_clk); cam_fsync=1;
            @(negedge cam_clk); cam_fsync=0;
        end
    endtask

    initial begin
        repeat (8) @(negedge cam_clk);
        rstn=1;
        repeat (8) @(negedge cam_clk);
        camera_vsync();
        repeat (20) @(negedge cam_clk);
        for (i=0;i<32;i=i+1) begin
            @(negedge cam_clk);
            cam_en=1;
            cam_pixel=i;
            if ((i%16)==15) begin
                @(negedge cam_clk); cam_en=0;
                repeat (8) @(negedge cam_clk);
            end
        end
        @(negedge cam_clk); cam_en=0;
        repeat (120) @(negedge cam_clk);
        if (sent_lines != 2 || accepted_lines != 2)
            $fatal(1,"line count %0d/%0d",sent_lines,accepted_lines);
        camera_vsync();
        repeat (20) @(negedge cam_clk);
        if (complete_count != 1) $fatal(1,"complete count %0d",complete_count);
        $display("PASS: raw camera FIFO packs two lines and publishes complete frame");
        $finish;
    end
endmodule
