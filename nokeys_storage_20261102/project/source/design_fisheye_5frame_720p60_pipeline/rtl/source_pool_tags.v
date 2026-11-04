`timescale 1ns/1ps

// Four tags and tree-PLRU share one 35-bit RAM word. Tag 255 is invalid:
// the maximum legal 720p block key is 28799, whose upper tag is 224.
// Clear 128 tag words on frame change, instead of resetting thousands of FFs.
module source_pool_tags #(
    parameter integer SET_BITS=7,
    parameter integer TAG_BITS=15-SET_BITS
) (
    input wire clock, reset_n, clear_i,
    output wire clear_busy_o,
    input wire read_valid_i, read_eligible_i,
    input wire [SET_BITS-1:0] read_set_i,
    input wire [TAG_BITS-1:0] read_tag_i,
    input wire [2:0] read_pixel_i,
    output wire hit_o,
    output wire [15:0] pixel_o,
    input wire fill_probe_i, fill_commit_i,
    input wire [SET_BITS-1:0] fill_set_i,
    input wire [TAG_BITS-1:0] fill_tag_i,
    input wire [2:0] fill_step_i,
    output wire external_write_o,
    output wire [SET_BITS+3:0] external_write_address_o, external_read_address_o,
    output wire [31:0] external_write_pixels_o,
    output wire external_pixel_half_o,
    input wire [15:0] external_pixel_i,
    input wire [127:0] fill_pixels_i
);
    localparam integer TAG_STORE_BITS=4*TAG_BITS;
    localparam integer WORD_BITS=TAG_STORE_BITS+3;
    reg ram_enabled_q /* synthesis syn_preserve=1 syn_keep=1 */;
    // A clear permits one old write, then the complete scrub invalidates it.
    // Local synchronous gating removes global control from the SRAM enable.
    always @(posedge clock)ram_enabled_q<=reset_n&&!clear_i;
    wire [WORD_BITS-1:0] tag_word;
    reg [WORD_BITS-1:0] fill_word, last_write_word;
    reg scrubbing, last_write_valid;
    reg [SET_BITS-1:0] clear_address, last_write_set;
    reg read_d1, eligible_d1, fill_d1;
    reg [SET_BITS-1:0] read_set_d1, fill_set_d1;
    reg [TAG_BITS-1:0] expected_d1, fill_tag_d1;
    reg [2:0] pixel_d1;
    reg [1:0] fill_way;
    wire [3:0] read_matches, fill_matches, free_ways;

    function [1:0] first_way;
        input [3:0] mask;
        begin
            if (mask[0]) first_way = 0;
            else if (mask[1]) first_way = 1;
            else if (mask[2]) first_way = 2;
            else first_way = 3;
        end
    endfunction

    function [2:0] touched;
        input [2:0] tree;
        input [1:0] way;
        begin
            touched = tree;
            touched[2] = !way[1];
            if (way[1]) touched[0] = !way[0];
            else touched[1] = !way[0];
        end
    endfunction

    // Forward the last replacement write across a same-address RAM read/write.
    // Tag values cannot change during the lookup pipeline: fills drain it first.
    wire [2:0] read_tree = last_write_valid && last_write_set == read_set_d1 ?
                           last_write_word[TAG_STORE_BITS+:3] : tag_word[TAG_STORE_BITS+:3];
    wire [2:0] fill_tree = tag_word[TAG_STORE_BITS+:3];
    wire [1:0] victim = {fill_tree[2], fill_tree[2] ? fill_tree[0] : fill_tree[1]};
    wire [1:0] read_way = first_way(read_matches);
    wire [1:0] selected_fill_way = (|fill_matches) ? first_way(fill_matches) :
                                          (|free_ways) ? first_way(free_ways) : victim;
    wire [WORD_BITS-1:0] replacement_word = {touched(read_tree, read_way), tag_word[TAG_STORE_BITS-1:0]};
    reg [WORD_BITS-1:0] new_fill_word;
    always @* begin
        new_fill_word = {touched(fill_tree, selected_fill_way), tag_word[TAG_STORE_BITS-1:0]};
        new_fill_word[selected_fill_way*TAG_BITS+:TAG_BITS] = fill_tag_d1;
    end
    assign clear_busy_o = scrubbing;
    assign hit_o = read_d1 && eligible_d1 && (|read_matches);

    genvar way;
    generate for (way = 0; way < 4; way = way + 1) begin: compare
        assign read_matches[way] = tag_word[way*TAG_BITS+:TAG_BITS] == expected_d1;
        assign fill_matches[way] = tag_word[way*TAG_BITS+:TAG_BITS] == fill_tag_d1;
        assign free_ways[way] = tag_word[way*TAG_BITS+:TAG_BITS] == {TAG_BITS{1'b1}};
    end endgenerate

    // Exactly one read and one write port. Fill already probes the whole word,
    // so its update fits the existing probe/commit phases without another read.
    wire tree_changes = replacement_word[TAG_STORE_BITS+:3] != tag_word[TAG_STORE_BITS+:3];
    wire tag_write_enable = ram_enabled_q && (scrubbing || fill_commit_i || (hit_o && tree_changes));
    wire [SET_BITS-1:0] tag_write_address = scrubbing ? clear_address :
                                   fill_commit_i ? fill_set_d1 : read_set_d1;
    wire [WORD_BITS-1:0] tag_write_data = scrubbing ? {3'd0,{TAG_STORE_BITS{1'b1}}} :
                                fill_commit_i ? fill_word : replacement_word;
    // Reads retain the same one-edge lookup stage. Tags cannot change during
    // outstanding lookups; PLRU same-address writes retain explicit forwarding.
    // Moving the stage to the address shortens coordinate -> RAM -> FF timing
    // and holds LUT-RAM addresses stable while idle.
    distributed_tag_ram #(.REGISTER_READ_ADDRESS(1),.SPLIT_TAG_WRITES(1),
                         .SET_BITS(SET_BITS),.TAG_BITS(TAG_BITS)) tag_memory (
        .clock(clock),
        .read_enable(ram_enabled_q && !scrubbing && (fill_probe_i || read_valid_i)),
        .read_address(fill_probe_i ? fill_set_i : read_set_i),
        .write_enable(tag_write_enable), .write_tags(scrubbing||fill_commit_i), .write_address(tag_write_address),
        .write_data(tag_write_data), .read_data(tag_word)
    );

    // At 32 sets, adjacent parity banks share a 36K true-dual-port RAM.
    // Each port owns a disjoint half. Four 32-bit writes precede tag publication.
    assign external_write_o=SET_BITS==5 && (fill_d1 || fill_step_i>=2 && fill_step_i<=4);
    wire [2:0] fill_part=fill_step_i-3'd1;
    assign external_write_address_o={fill_set_d1,
        fill_d1 ? selected_fill_way : fill_way, fill_part[1:0]};
    assign external_write_pixels_o=fill_pixels_i[fill_part[1:0]*32+:32];
    assign external_read_address_o={read_set_d1,read_way,pixel_d1[2:1]};
    assign external_pixel_half_o=pixel_d1[0];
    generate if(SET_BITS==5)begin: paired_data
        assign pixel_o=external_pixel_i;
    end else begin: independent_data
    // Compact geometry uses the existing probe/commit edges for two half writes.
    // Tag publication remains on the second write; no lookup can see half a fill.
    localparam integer DATA_WRITE_BITS=SET_BITS==6 ? SET_BITS+3 : SET_BITS+2;
    localparam integer DATA_WRITE_WIDTH=SET_BITS==6 ? 64 : 128;
    wire data_write_enable=SET_BITS==6 ? (fill_d1||fill_commit_i) : fill_commit_i;
    wire [DATA_WRITE_BITS-1:0] data_write_address;
    wire [DATA_WRITE_WIDTH-1:0] data_write_pixels;
    if(SET_BITS==6)begin: compact_fill
        assign data_write_address={fill_set_d1,
            fill_commit_i ? fill_way : selected_fill_way,fill_commit_i};
        assign data_write_pixels=fill_commit_i ? fill_pixels_i[127:64] : fill_pixels_i[63:0];
    end else begin: full_fill
        assign data_write_address={fill_set_d1,fill_way};
        assign data_write_pixels=fill_pixels_i;
    end
    // Reuse the supplied vendor implementation unchanged, with legal geometry.
    ipm2l_sdpram_v1_10_wr_fram_buf #(
        .c_CAS_MODE("36K"), .c_WR_ADDR_WIDTH(DATA_WRITE_BITS), .c_WR_DATA_WIDTH(DATA_WRITE_WIDTH),
        .c_RD_ADDR_WIDTH(SET_BITS+5), .c_RD_DATA_WIDTH(16), .c_OUTPUT_REG(0),
        .c_WR_CLK_EN(1), .c_RD_CLK_EN(1), .c_RESET_TYPE("SYNC")
    ) data_ram (
        .wr_addr(data_write_address), .wr_data(data_write_pixels), .wr_en(data_write_enable),
        .wr_clk(clock), .wr_clk_en(data_write_enable), .wr_rst(!reset_n),
        .wr_byte_en(8'hff), .wr_addr_strobe(1'b0),
        .rd_addr({read_set_d1, read_way, pixel_d1}), .rd_data(pixel_o),
        .rd_clk(clock), .rd_clk_en(hit_o), .rd_rst(!reset_n),
        .rd_oce(1'b1), .rd_addr_strobe(1'b0)
    );
    end endgenerate

    always @(posedge clock) begin
        if (!reset_n || clear_i) begin
            scrubbing <= 1; clear_address <= 0;
            read_d1 <= 0; fill_d1 <= 0; eligible_d1 <= 0;
            fill_way <= 0; last_write_valid <= 0;
        end else begin
            if (scrubbing && ram_enabled_q) begin
                clear_address <= clear_address + 1'b1;
                if (clear_address == (1<<SET_BITS)-1) scrubbing <= 0;
            end
            read_d1 <= read_valid_i && !scrubbing;
            fill_d1 <= fill_probe_i && !scrubbing;
            eligible_d1 <= read_valid_i && read_eligible_i;
            if (read_valid_i) begin
                read_set_d1 <= read_set_i; expected_d1 <= read_tag_i; pixel_d1 <= read_pixel_i;
            end
            if (fill_probe_i) begin fill_set_d1 <= fill_set_i; fill_tag_d1 <= fill_tag_i; end
            if (fill_d1) begin fill_way <= selected_fill_way; fill_word <= new_fill_word; end
            last_write_valid <= !scrubbing && (fill_commit_i || hit_o);
            if (fill_commit_i) begin last_write_set <= fill_set_d1; last_write_word <= fill_word; end
            else if (hit_o) begin last_write_set <= read_set_d1; last_write_word <= replacement_word; end
        end
    end
endmodule
