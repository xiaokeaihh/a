`timescale 1ns/1ps

// Full 1080p frame with synthetic camera/HDMI DDR bursts contending through
// the actual two-master arbiter. This is a bandwidth test, not a DDR PHY model.
module tb_renderer_video_contention;
    localparam integer FRAME_BUDGET_CYCLES = 4166666;
    parameter integer STALL_MOD = 4;
    // Eight 16-beat bursts per 1920-pixel RGB565 line, approximately one
    // 128-beat line every 3744 DDR cycles (1080 lines per 33 ms).
    localparam integer LEGACY_BURST_SPACING = 468;

    reg clock = 1'b0;
    always #4 clock = ~clock;
    reg reset_n = 1'b0;
    reg start_i = 1'b0;
    wire done_o, error_o, busy_o;

    wire [27:0] m1_awaddr, m1_araddr;
    wire [3:0] m1_awlen, m1_awid, m1_arlen, m1_arid;
    wire m1_awvalid, m1_awready, m1_wready, m1_wlast;
    wire [255:0] m1_wdata, m1_rdata;
    wire [31:0] m1_wstrb;
    wire m1_arvalid, m1_arready, m1_rvalid, m1_rlast;
    wire [3:0] m1_rid;

    reg m0_awvalid = 1'b0;
    reg m0_arvalid = 1'b0;
    wire m0_awready, m0_arready, m0_wready, m0_wlast;
    wire [255:0] m0_rdata;
    wire m0_rvalid, m0_rlast;
    wire [3:0] m0_rid;

    wire [27:0] ddr_awaddr, ddr_araddr;
    wire [3:0] ddr_awlen, ddr_awid, ddr_arlen, ddr_arid;
    wire ddr_awvalid, ddr_arvalid;
    wire [255:0] ddr_wdata;
    wire [31:0] ddr_wstrb;
    wire ddr_awready, ddr_arready, ddr_wready, ddr_wlast;
    reg [255:0] ddr_rdata = {16{16'hffff}};
    reg ddr_rvalid = 1'b0;
    reg ddr_rlast = 1'b0;
    reg [3:0] ddr_rid = 4'd0;

    integer tick = 0;
    integer next_m0_write = 1;
    integer next_m0_read = 235;
    integer camera_bursts = 0;
    integer hdmi_bursts = 0;
    integer corrected_rows = 0;
    reg write_active = 1'b0;
    reg read_active = 1'b0;
    reg [4:0] write_beats_left = 5'd0;
    reg [4:0] read_beats_left = 5'd0;

    assign ddr_awready = !write_active && (tick % STALL_MOD) != 1;
    assign ddr_arready = !read_active && (tick % STALL_MOD) != 0;
    assign ddr_wready = write_active && (tick % STALL_MOD) != STALL_MOD-2;
    assign ddr_wlast = write_active && write_beats_left == 5'd1;

    tile_renderer renderer (
        .clock(clock), .reset_n(reset_n), .start_i(start_i),
        .source_bank_i(2'd0), .destination_bank_i(2'd0),
        .busy_o(busy_o), .done_o(done_o), .error_o(error_o),
        .cal_write_en_i(1'b0), .cal_table_select_i(1'b0),
        .cal_write_addr_i(14'd0), .cal_write_data_i(48'd0),
        .cal_commit_i(1'b0), .calibration_loaded_o(),
        .axi_araddr(m1_araddr), .axi_arlen(m1_arlen),
        .axi_arid(m1_arid), .axi_arvalid(m1_arvalid),
        .axi_arready(m1_arready), .axi_rdata(m1_rdata),
        .axi_rvalid(m1_rvalid), .axi_rlast(m1_rlast),
        .axi_awaddr(m1_awaddr), .axi_awlen(m1_awlen),
        .axi_awid(m1_awid), .axi_awvalid(m1_awvalid),
        .axi_awready(m1_awready), .axi_wdata(m1_wdata),
        .axi_wstrb(m1_wstrb), .axi_wready(m1_wready),
        .axi_wlast(m1_wlast)
    );

    ddr_burst_arbiter arbiter (
        .clock(clock), .reset_n(reset_n),
        .m0_awaddr(28'h0000000), .m0_awlen(4'd15), .m0_awid(4'd0),
        .m0_awvalid(m0_awvalid), .m0_awready(m0_awready),
        .m0_wdata(256'd0), .m0_wstrb(32'hffff_ffff),
        .m0_wready(m0_wready), .m0_wlast(m0_wlast),
        .m1_awaddr(m1_awaddr), .m1_awlen(m1_awlen), .m1_awid(m1_awid),
        .m1_awvalid(m1_awvalid), .m1_awready(m1_awready),
        .m1_wdata(m1_wdata), .m1_wstrb(m1_wstrb),
        .m1_wready(m1_wready), .m1_wlast(m1_wlast),
        .m0_araddr(28'h0c00000), .m0_arlen(4'd15), .m0_arid(4'd0),
        .m0_arvalid(m0_arvalid), .m0_arready(m0_arready),
        .m0_rdata(m0_rdata), .m0_rvalid(m0_rvalid),
        .m0_rlast(m0_rlast), .m0_rid(m0_rid),
        .m1_araddr(m1_araddr), .m1_arlen(m1_arlen), .m1_arid(m1_arid),
        .m1_arvalid(m1_arvalid), .m1_arready(m1_arready),
        .m1_rdata(m1_rdata), .m1_rvalid(m1_rvalid),
        .m1_rlast(m1_rlast), .m1_rid(m1_rid),
        .ddr_awaddr(ddr_awaddr), .ddr_awlen(ddr_awlen),
        .ddr_awid(ddr_awid), .ddr_awvalid(ddr_awvalid),
        .ddr_awready(ddr_awready), .ddr_wdata(ddr_wdata),
        .ddr_wstrb(ddr_wstrb), .ddr_wready(ddr_wready),
        .ddr_wlast(ddr_wlast),
        .ddr_araddr(ddr_araddr), .ddr_arlen(ddr_arlen),
        .ddr_arid(ddr_arid), .ddr_arvalid(ddr_arvalid),
        .ddr_arready(ddr_arready), .ddr_rdata(ddr_rdata),
        .ddr_rvalid(ddr_rvalid), .ddr_rlast(ddr_rlast),
        .ddr_rid(ddr_rid)
    );

    always @(posedge clock) begin
        if (!reset_n) begin
            tick <= 0;
            m0_awvalid <= 1'b0;
            m0_arvalid <= 1'b0;
            next_m0_write <= 1;
            next_m0_read <= 235;
            camera_bursts <= 0;
            hdmi_bursts <= 0;
            corrected_rows <= 0;
            write_active <= 1'b0;
            read_active <= 1'b0;
            write_beats_left <= 5'd0;
            read_beats_left <= 5'd0;
            ddr_rvalid <= 1'b0;
            ddr_rlast <= 1'b0;
        end else begin
            tick <= tick + 1;

            if (!m0_awvalid && tick >= next_m0_write) begin
                m0_awvalid <= 1'b1;
                next_m0_write <= next_m0_write + LEGACY_BURST_SPACING;
            end else if (m0_awvalid && m0_awready) begin
                m0_awvalid <= 1'b0;
                camera_bursts <= camera_bursts + 1;
            end

            if (!m0_arvalid && tick >= next_m0_read) begin
                m0_arvalid <= 1'b1;
                next_m0_read <= next_m0_read + LEGACY_BURST_SPACING;
            end else if (m0_arvalid && m0_arready) begin
                m0_arvalid <= 1'b0;
                hdmi_bursts <= hdmi_bursts + 1;
            end

            if (ddr_awvalid && ddr_awready && !write_active) begin
                write_active <= 1'b1;
                write_beats_left <= {1'b0, ddr_awlen} + 5'd1;
            end
            if (m1_awvalid && m1_awready)
                corrected_rows <= corrected_rows + 1;
            if (write_active && ddr_wready) begin
                write_beats_left <= write_beats_left - 5'd1;
                if (write_beats_left == 5'd1)
                    write_active <= 1'b0;
            end

            ddr_rvalid <= 1'b0;
            ddr_rlast <= 1'b0;
            if (ddr_arvalid && ddr_arready && !read_active) begin
                read_active <= 1'b1;
                read_beats_left <= {1'b0, ddr_arlen} + 5'd1;
            end
            if (read_active && (tick % STALL_MOD) != STALL_MOD-1) begin
                ddr_rvalid <= 1'b1;
                ddr_rdata <= {16{16'hffff}};
                ddr_rlast <= read_beats_left == 5'd1;
                read_beats_left <= read_beats_left - 5'd1;
                if (read_beats_left == 5'd1)
                    read_active <= 1'b0;
            end
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

        for (cycles = 0; cycles < FRAME_BUDGET_CYCLES; cycles = cycles + 1) begin
            @(negedge clock);
            if (done_o) begin
                if (error_o || corrected_rows != 16200)
                    $fatal(1, "Renderer failed: error=%b corrected_rows=%0d",
                           error_o, corrected_rows);
                $display("PASS tb_renderer_video_contention cycles=%0d frame_ms=%f stall_mod=%0d camera_bursts=%0d hdmi_bursts=%0d",
                         cycles, cycles * 0.000008, STALL_MOD,
                         camera_bursts, hdmi_bursts);
                $finish;
            end
        end
        $fatal(1, "Renderer missed 33.33 ms: corrected_rows=%0d camera=%0d hdmi=%0d",
               corrected_rows, camera_bursts, hdmi_bursts);
    end
endmodule
