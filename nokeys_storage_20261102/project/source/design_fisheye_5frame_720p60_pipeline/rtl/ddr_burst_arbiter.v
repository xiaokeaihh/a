`timescale 1ns/1ps

// Two independent write and read masters sharing the board's DDR3 AXI port.
// Master 0 is camera write / HDMI read; master 1 is corrected-frame write /
// source-tile prefetch. Transactions are serialized per direction because the
// DDR3 IP exposes no WVALID or RREADY backpressure ports.
module ddr_burst_arbiter (
    input  wire         clock,
    input  wire         reset_n,

    input  wire [27:0]  m0_awaddr,
    input  wire [3:0]   m0_awlen,
    input  wire [3:0]   m0_awid,
    input  wire         m0_awvalid,
    output wire         m0_awready,
    input  wire [255:0] m0_wdata,
    input  wire [31:0]  m0_wstrb,
    output wire         m0_wready,
    output wire         m0_wlast,
    input  wire [27:0]  m1_awaddr,
    input  wire [3:0]   m1_awlen,
    input  wire [3:0]   m1_awid,
    input  wire         m1_awvalid,
    output wire         m1_awready,
    input  wire [255:0] m1_wdata,
    input  wire [31:0]  m1_wstrb,
    output wire         m1_wready,
    output wire         m1_wlast,

    input  wire [27:0]  m0_araddr,
    input  wire [3:0]   m0_arlen,
    input  wire [3:0]   m0_arid,
    input  wire         m0_arvalid,
    output wire         m0_arready,
    output wire [255:0] m0_rdata,
    output wire         m0_rvalid,
    output wire         m0_rlast,
    output wire [3:0]   m0_rid,
    input  wire [27:0]  m1_araddr,
    input  wire [3:0]   m1_arlen,
    input  wire [3:0]   m1_arid,
    input  wire         m1_arvalid,
    output wire         m1_arready,
    output wire [255:0] m1_rdata,
    output wire         m1_rvalid,
    output wire         m1_rlast,
    output wire [3:0]   m1_rid,

    output wire [27:0]  ddr_awaddr,
    output wire [3:0]   ddr_awlen,
    output wire [3:0]   ddr_awid,
    output wire         ddr_awvalid,
    input  wire         ddr_awready,
    output wire [255:0] ddr_wdata,
    output wire [31:0]  ddr_wstrb,
    input  wire         ddr_wready,
    input  wire         ddr_wlast,
    output wire [27:0]  ddr_araddr,
    output wire [3:0]   ddr_arlen,
    output wire [3:0]   ddr_arid,
    output wire         ddr_arvalid,
    input  wire         ddr_arready,
    input  wire [255:0] ddr_rdata,
    input  wire         ddr_rvalid,
    input  wire         ddr_rlast,
    input  wire [3:0]   ddr_rid
);
    reg write_busy;
    reg write_owner;
    reg read_busy;
    reg read_owner;

    // Port 0 has priority for the time-critical camera and HDMI streams.
    wire pending_write_owner = !m0_awvalid;
    wire pending_read_owner = !m0_arvalid;

    assign ddr_awvalid = !write_busy && (m0_awvalid || m1_awvalid);
    assign ddr_awaddr = pending_write_owner ? m1_awaddr : m0_awaddr;
    assign ddr_awlen = pending_write_owner ? m1_awlen : m0_awlen;
    assign ddr_awid = pending_write_owner ? m1_awid : m0_awid;
    assign m0_awready = !write_busy && !pending_write_owner && ddr_awready;
    assign m1_awready = !write_busy && pending_write_owner && ddr_awready;
    assign ddr_wdata = write_owner ? m1_wdata : m0_wdata;
    assign ddr_wstrb = write_owner ? m1_wstrb : m0_wstrb;
    assign m0_wready = write_busy && !write_owner && ddr_wready;
    assign m1_wready = write_busy && write_owner && ddr_wready;
    assign m0_wlast = write_busy && !write_owner && ddr_wlast;
    assign m1_wlast = write_busy && write_owner && ddr_wlast;

    assign ddr_arvalid = !read_busy && (m0_arvalid || m1_arvalid);
    assign ddr_araddr = pending_read_owner ? m1_araddr : m0_araddr;
    assign ddr_arlen = pending_read_owner ? m1_arlen : m0_arlen;
    assign ddr_arid = pending_read_owner ? m1_arid : m0_arid;
    assign m0_arready = !read_busy && !pending_read_owner && ddr_arready;
    assign m1_arready = !read_busy && pending_read_owner && ddr_arready;
    assign m0_rdata = ddr_rdata;
    assign m1_rdata = ddr_rdata;
    assign m0_rvalid = read_busy && !read_owner && ddr_rvalid;
    assign m1_rvalid = read_busy && read_owner && ddr_rvalid;
    assign m0_rlast = read_busy && !read_owner && ddr_rlast;
    assign m1_rlast = read_busy && read_owner && ddr_rlast;
    assign m0_rid = ddr_rid;
    assign m1_rid = ddr_rid;

    always @(posedge clock) begin
        if (!reset_n) begin
            write_busy <= 1'b0;
            write_owner <= 1'b0;
            read_busy <= 1'b0;
            read_owner <= 1'b0;
        end else begin
            if (!write_busy && ddr_awvalid && ddr_awready) begin
                write_busy <= 1'b1;
                write_owner <= pending_write_owner;
            end else if (write_busy && ddr_wready && ddr_wlast) begin
                write_busy <= 1'b0;
            end

            if (!read_busy && ddr_arvalid && ddr_arready) begin
                read_busy <= 1'b1;
                read_owner <= pending_read_owner;
            end else if (read_busy && ddr_rvalid && ddr_rlast) begin
                read_busy <= 1'b0;
            end
        end
    end
endmodule
