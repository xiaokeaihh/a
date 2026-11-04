`timescale 1ns/1ps
module tb_tile_renderer_full_frame_stress;
    reg clock = 1'b0;
    always #4 clock = ~clock;

    reg reset_n = 1'b0;
    reg start_i = 1'b0;
    wire busy_o;
    wire done_o;
    wire error_o;
    wire [27:0] axi_araddr;
    wire [3:0] axi_arlen, axi_arid;
    wire axi_arvalid;
    reg [255:0] axi_rdata = 256'd0;
    reg axi_rvalid = 1'b0;
    reg axi_rlast = 1'b0;
    wire [27:0] axi_awaddr;
    wire [3:0] axi_awlen, axi_awid;
    wire axi_awvalid;
    wire [255:0] axi_wdata;
    wire [31:0] axi_wstrb;
    wire axi_wlast;
    wire axi_wready;

    reg read_active = 1'b0;
    reg [4:0] read_beats_left = 5'd0;
    reg write_active = 1'b0;
    reg [2:0] write_beat = 3'd0;
    integer completed_rows = 0;
    reg overlap_seen = 1'b0;
    integer tick = 0;
    wire axi_arready = (tick % 4) != 0;
    wire axi_awready = (tick % 4) != 1;
    assign axi_wready = write_active && (tick % 4) != 2;
    assign axi_wlast = write_active && write_beat == 3'd7;

    tile_renderer dut (
        .clock(clock), .reset_n(reset_n), .start_i(start_i),
        .source_bank_i(2'd0), .destination_bank_i(2'd0),
        .busy_o(busy_o), .done_o(done_o), .error_o(error_o),
        .cal_write_en_i(1'b0), .cal_table_select_i(1'b0),
        .cal_write_addr_i(14'd0), .cal_write_data_i(48'd0),
        .cal_commit_i(1'b0), .calibration_loaded_o(),
        .axi_araddr(axi_araddr), .axi_arlen(axi_arlen),
        .axi_arid(axi_arid), .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready), .axi_rdata(axi_rdata),
        .axi_rvalid(axi_rvalid), .axi_rlast(axi_rlast),
        .axi_awaddr(axi_awaddr), .axi_awlen(axi_awlen),
        .axi_awid(axi_awid), .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready), .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
        .axi_wlast(axi_wlast)
    );

    always @(posedge clock) begin
        if (!reset_n) begin
            read_active <= 1'b0;
            read_beats_left <= 5'd0;
            axi_rvalid <= 1'b0;
            axi_rlast <= 1'b0;
            write_active <= 1'b0;
            write_beat <= 3'd0;
            completed_rows <= 0;
            overlap_seen <= 1'b0;
            tick <= 0;
        end else begin
            tick <= tick + 1;
            axi_rvalid <= 1'b0;
            axi_rlast <= 1'b0;
            if (axi_arvalid && axi_arready && !read_active) begin
                read_active <= 1'b1;
                read_beats_left <= {1'b0, axi_arlen} + 5'd1;
            end
            if (read_active && (tick % 4) != 3) begin
                axi_rvalid <= 1'b1;
                axi_rdata <= {16{16'hffff}};
                axi_rlast <= read_beats_left == 5'd1;
                read_beats_left <= read_beats_left - 5'd1;
                if (read_beats_left == 5'd1)
                    read_active <= 1'b0;
            end

            if (axi_awvalid && axi_awready && !write_active) begin
                write_active <= 1'b1;
                write_beat <= 3'd0;
                completed_rows <= completed_rows + 1;
            end
            if (write_active && axi_wready) begin
                if (write_beat == 3'd7)
                    write_active <= 1'b0;
                else
                    write_beat <= write_beat + 3'd1;
            end

            if (dut.render_state == 3'd2 && dut.prefetch_busy
                && dut.prefetch_cache != dut.render_cache)
                overlap_seen <= 1'b1;
        end
    end

    integer cycles;
    initial begin
        repeat (5) @(negedge clock);
        reset_n = 1'b1;
        @(negedge clock);
        start_i = 1'b1;
        @(negedge clock);
        start_i = 1'b0;

        for (cycles = 0; cycles < 4166666; cycles = cycles + 1) begin
            @(negedge clock);
            if (done_o) begin
                if (error_o || completed_rows != 16200 || !overlap_seen)
                    $fatal(1, "renderer failed: error=%b rows=%0d overlap=%b",
                           error_o, completed_rows, overlap_seen);
                $display("PASS tb_tile_renderer_full_frame_stress cycles=%0d frame_ms=%f", cycles, cycles * 0.000008);
                $finish;
            end
        end
        $fatal(1, "renderer did not complete within 4166666 cycles");
    end
endmodule
