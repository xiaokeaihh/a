`timescale 1ns/1ps
module tb_fiveframe_display_fifo;
    reg ddr_clk=0, pix_clk=0, rstn=0;
    always #4 ddr_clk=~ddr_clk;
    always #7 pix_clk=~pix_clk;
    reg rd_fsync=0, rd_en=0;
    reg [255:0] ddr_data=0;
    reg ddr_data_en=0, ddr_done=0;
    wire ddr_req, vout_de, frame_rirq;
    wire [27:0] ddr_addr;
    wire [31:0] ddr_len;
    wire [15:0] vout_data;
    rd_buf #(.H_NUM(16), .V_NUM(2), .PIX_WIDTH(16)) display (
        .ddr_clk(ddr_clk), .ddr_rstn(rstn),
        .vout_clk(pix_clk), .rd_fsync(rd_fsync), .rd_en(rd_en),
        .vout_de(vout_de), .vout_data(vout_data),
        .init_done(1'b1), .read_bank(2'd0), .frame_rirq(frame_rirq),
        .ddr_rreq(ddr_req), .ddr_raddr(ddr_addr),
        .ddr_rd_len(ddr_len), .ddr_rrdy(1'b1), .ddr_rdone(ddr_done),
        .ddr_rdata(ddr_data), .ddr_rdata_en(ddr_data_en)
    );
    integer i, line_count=0, pixel_count=0, expected_pixel;
    reg [255:0] line_data;
    always @(posedge ddr_clk) begin
        ddr_data_en <= 0;
        ddr_done <= 0;
        if (ddr_req) begin
            if (ddr_len !== 1) $fatal(1,"bad read length");
            if (ddr_addr !== (line_count == 0 ? 8 : 0))
                $fatal(1,"vertical order lost: addr=%h line=%0d",ddr_addr,line_count);
            for (integer j=0;j<16;j=j+1)
                line_data[j*16 +:16] = (line_count == 0 ? 100 : 0)+j;
            ddr_data <= line_data;
            ddr_data_en <= 1;
        end
        if (ddr_data_en) begin
            ddr_done <= 1;
            line_count=line_count+1;
        end
    end
    always @(posedge pix_clk) begin
        #1;
        if (vout_de) begin
            expected_pixel = (pixel_count < 16 ? 100 : 0)+(pixel_count%16);
            if (vout_data !== expected_pixel[15:0])
                $fatal(1,"pixel %0d got %h expected %h",pixel_count,vout_data,expected_pixel[15:0]);
            pixel_count=pixel_count+1;
        end
    end
    initial begin
        repeat (5) @(negedge pix_clk);
        rstn=1;
        repeat (8) @(negedge pix_clk);
        rd_fsync=1;
        @(negedge pix_clk); rd_fsync=0;
        repeat (80) @(negedge pix_clk);
        if (line_count != 2) $fatal(1,"DDR line count %0d",line_count);
        for (i=0;i<16;i=i+1) begin
            @(negedge pix_clk); rd_en=1;
        end
        @(negedge pix_clk); rd_en=0;
        repeat (10) @(negedge pix_clk);
        for (i=0;i<16;i=i+1) begin
            @(negedge pix_clk); rd_en=1;
        end
        @(negedge pix_clk); rd_en=0;
        repeat (8) @(negedge pix_clk);
        if (pixel_count != 32) $fatal(1,"pixel count %0d",pixel_count);
        $display("PASS: display FIFO preserves RGB565 and bottom-to-top order");
        $finish;
    end
endmodule
