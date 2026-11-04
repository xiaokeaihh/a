`timescale 1ns/1ps

// 32 KiB shared source pool, four parity banks and four ways per set.
// Lookups pipeline at one pixel/clock. Fill probes use the tag read port
// only after outstanding lookups drain; the camera tap may skip busy fills.
module associative_source_pool #(
    parameter integer SET_BITS=7
) (
    input wire clock, reset_n, frame_start_i,
    input wire [31:0] frame_id_i,
    input wire [1:0] source_bank_i,
    input wire column_major_i,
    input wire fill_valid_i,
    input wire [31:0] fill_frame_i,
    input wire [1:0] fill_bank_i,
    input wire [10:0] fill_x_i, fill_y_i,
    input wire [255:0] fill_pixels_i,
    output wire fill_ready_o,
    input wire lookup_valid_i,
    output wire lookup_ready_o,
    input wire [31:0] lookup_frame_i,
    input wire [1:0] lookup_bank_i,
    input wire [10:0] lookup_x_i, lookup_y_i,
    output reg lookup_valid_o, hit_o,
    output reg [3:0] miss_mask_o,
    output reg [63:0] pixels_o,
    output reg error_o
);
    localparam FILL_IDLE=3'd0, FILL_PROBE=3'd1, FILL_COMMIT=SET_BITS==5 ? 3'd4 : 3'd2;
    reg [2:0] fill_state;
    reg [31:0] active_frame;
    reg [1:0] active_bank;
    reg active_column_major, fill_row;
    reg [255:0] buffered_fill;
    reg token_d1, token_d2;
    reg [1:0] origin_d1, origin_d2;
    reg [3:0] hits_d2;
    wire [3:0] bank_hits;
    wire [3:0] bank_clear_busy;
    wire [63:0] bank_pixels;

    function [14:0] source_key;
        input [10:0] x, y;
        input column_major;
        reg [14:0] row_pair, column;
        begin
            row_pair = y >> 1; column = x >> 4;
            source_key = column_major ? (column << 8) + (column << 6) +
                         (column << 5) + (column << 3) + row_pair :
                         (row_pair << 6) + (row_pair << 4) + column;
        end
    endfunction

    function [SET_BITS-1:0] set_index;
        input [14:0] key;
        begin
            set_index = key[SET_BITS-1:0] ^ key[2*SET_BITS-1:SET_BITS];
            if(SET_BITS==6) set_index = set_index ^ key[14:12];
            if(SET_BITS==5) set_index = set_index ^ key[14:10];
        end
    endfunction

    wire fill_identity_matches = fill_frame_i == active_frame && fill_bank_i == active_bank;
    wire fill_coordinates_valid = fill_x_i <= 1264 && fill_x_i[3:0] == 0 && fill_y_i < 720;
    wire lookup_identity_matches = lookup_frame_i == active_frame && lookup_bank_i == active_bank;
    wire lookup_coordinates_valid = lookup_x_i < 1279 && lookup_y_i < 719;
    assign lookup_ready_o = reset_n && !frame_start_i && !(|bank_clear_busy) && fill_state == FILL_IDLE;
    assign fill_ready_o = lookup_ready_o && !lookup_valid_i && !token_d1 && !token_d2 &&
                          fill_identity_matches && fill_coordinates_valid;
    wire accept_lookup = lookup_valid_i && lookup_ready_o;
    wire accept_fill = fill_valid_i && fill_ready_o;
    wire [14:0] fill_key = source_key(fill_x_i, fill_y_i, active_column_major);
    wire [63:0] valid_bank_pixels;

    wire [3:0] data_write, data_half;
    wire [4*(SET_BITS+4)-1:0] data_wraddr,data_rdaddr;
    wire [127:0] data_wdata;
    wire [63:0] paired_pixels;
    genvar bank, pixel;
    generate for (bank = 0; bank < 4; bank = bank + 1) begin: banks
        wire [10:0] request_x = lookup_x_i + (lookup_x_i[0] != bank % 2);
        wire [10:0] request_y = lookup_y_i + (lookup_y_i[0] != bank / 2);
        wire [14:0] request_key = source_key(request_x, request_y, active_column_major);
        wire [127:0] fill_word;
        for (pixel = 0; pixel < 8; pixel = pixel + 1) begin: pack
            assign fill_word[pixel*16+:16] = buffered_fill[(pixel*2+bank%2)*16+:16];
        end
        source_pool_tags #(.SET_BITS(SET_BITS)) bank_storage (
            .clock(clock), .reset_n(reset_n), .clear_i(frame_start_i), .clear_busy_o(bank_clear_busy[bank]),
            .read_valid_i(accept_lookup),
            .read_eligible_i(lookup_identity_matches && lookup_coordinates_valid),
            .read_set_i(set_index(request_key)), .read_tag_i(request_key[14:SET_BITS]),
            .read_pixel_i(request_x[3:1]), .hit_o(bank_hits[bank]),
            .pixel_o(bank_pixels[bank*16+:16]),
            .fill_probe_i(accept_fill && fill_y_i[0] == bank/2),
            .fill_commit_i(fill_state == FILL_COMMIT && fill_row == bank/2 && !frame_start_i),
            .fill_step_i(fill_row==bank/2 ? fill_state : 3'd0),
            .external_write_o(data_write[bank]),
            .external_write_address_o(data_wraddr[bank*(SET_BITS+4)+:SET_BITS+4]),
            .external_read_address_o(data_rdaddr[bank*(SET_BITS+4)+:SET_BITS+4]),
            .external_write_pixels_o(data_wdata[bank*32+:32]),
            .external_pixel_half_o(data_half[bank]),.external_pixel_i(paired_pixels[bank*16+:16]),
            .fill_set_i(set_index(fill_key)), .fill_tag_i(fill_key[14:SET_BITS]), .fill_pixels_i(fill_word)
        );
        assign valid_bank_pixels[bank*16+:16] = hits_d2[bank] ? bank_pixels[bank*16+:16] : 16'd0;
    end endgenerate

    genvar row;
    generate if(SET_BITS==5)begin: compact_pairs
        for(row=0;row<2;row=row+1)begin: pair
            source_pool_pair_ram memory(
                .clock(clock),.reset_n(reset_n),
                .write_a_i(data_write[row*2]),.write_b_i(data_write[row*2+1]),
                .read_a_i(bank_hits[row*2]),.read_b_i(bank_hits[row*2+1]),
                .write_address_a_i(data_wraddr[(row*2)*9+:9]),
                .write_address_b_i(data_wraddr[(row*2+1)*9+:9]),
                .read_address_a_i(data_rdaddr[(row*2)*9+:9]),
                .read_address_b_i(data_rdaddr[(row*2+1)*9+:9]),
                .write_data_a_i(data_wdata[row*64+:32]),.write_data_b_i(data_wdata[row*64+32+:32]),
                .half_a_i(data_half[row*2]),.half_b_i(data_half[row*2+1]),
                .pixel_a_o(paired_pixels[row*32+:16]),.pixel_b_o(paired_pixels[row*32+16+:16]));
        end
    end else begin: original_data
        assign paired_pixels=0;
    end endgenerate

    always @(posedge clock) begin
        if (!reset_n || frame_start_i) begin
            fill_state <= FILL_IDLE; buffered_fill <= 0; fill_row <= 0;
            token_d1 <= 0; token_d2 <= 0; lookup_valid_o <= 0;
            hit_o <= 0; miss_mask_o <= 4'hf; pixels_o <= 0; error_o <= 0;
            if (!reset_n) begin active_frame <= 0; active_bank <= 0; active_column_major <= 0; end
            else begin
                active_frame <= frame_id_i; active_bank <= source_bank_i;
                active_column_major <= column_major_i;
                if (source_bank_i >= 3) error_o <= 1;
            end
        end else begin
            case (fill_state)
                FILL_IDLE: if (accept_fill) begin
                    buffered_fill <= fill_pixels_i; fill_row <= fill_y_i[0]; fill_state <= FILL_PROBE;
                end
                FILL_PROBE: fill_state <= 3'd2;
                FILL_COMMIT: fill_state <= FILL_IDLE;
                default: begin
                    if(SET_BITS==5 && fill_state>=2 && fill_state<4)fill_state<=fill_state+1'b1;
                    else begin fill_state<=FILL_IDLE;error_o<=1;end
                end
            endcase
            token_d1 <= accept_lookup; token_d2 <= token_d1; lookup_valid_o <= token_d2;
            if (accept_lookup) origin_d1 <= {lookup_y_i[0], lookup_x_i[0]};
            if (token_d1) begin hits_d2 <= bank_hits; origin_d2 <= origin_d1; end
            if (token_d2) begin
                hit_o <= &hits_d2; miss_mask_o <= ~hits_d2;
                // Partial hits are explicit. Consumers must use the miss mask
                // before retaining any of the ordered TL/TR/BL/BR pixels.
                pixels_o <= {valid_bank_pixels[(origin_d2 ^ 2'd3)*16+:16],
                             valid_bank_pixels[(origin_d2 ^ 2'd2)*16+:16],
                             valid_bank_pixels[(origin_d2 ^ 2'd1)*16+:16],
                             valid_bank_pixels[origin_d2*16+:16]};
            end
            if (fill_valid_i && fill_identity_matches && !fill_coordinates_valid) error_o <= 1;
        end
    end
endmodule

// A 1024x32 true-dual-port block replaces two half-empty independent blocks.
// Port A owns addresses 0..511, B owns 512..1023. Cache fills drain reads,
// and tags are published only on the fourth and final data-write edge.
module source_pool_pair_ram(
    input wire clock,reset_n,write_a_i,write_b_i,read_a_i,read_b_i,
    input wire [8:0] write_address_a_i,write_address_b_i,read_address_a_i,read_address_b_i,
    input wire [31:0] write_data_a_i,write_data_b_i,
    input wire half_a_i,half_b_i,
    output wire [15:0] pixel_a_o,pixel_b_o
);
    wire [8:0] address_a=write_a_i?write_address_a_i:read_address_a_i;
    wire [8:0] address_b=write_b_i?write_address_b_i:read_address_b_i;
    wire [35:0] qa,qb;
    wire [31:0] word_a={qa[34:27],qa[25:18],qa[16:9],qa[7:0]};
    wire [31:0] word_b={qb[34:27],qb[25:18],qb[16:9],qb[7:0]};
    reg half_a,half_b;
    always @(posedge clock)begin
        if(read_a_i)half_a<=half_a_i;
        if(read_b_i)half_b<=half_b_i;
    end
    assign pixel_a_o=half_a?word_a[31:16]:word_a[15:0];
    assign pixel_b_o=half_b?word_b[31:16]:word_b[15:0];
    GTP_DRM36K_E1 #(.GRS_EN("FALSE"),.RAM_MODE("TRUE_DUAL_PORT"),
        .DATA_WIDTH_A(32),.DATA_WIDTH_B(32),.RAM_ADDR_WIDTH(10),.RAM_DATA_WIDTH(32),
        .WRITE_MODE_A("NORMAL_WRITE"),.WRITE_MODE_B("NORMAL_WRITE"),
        .DOA_REG(0),.DOB_REG(0),.RST_TYPE("SYNC")) ram(
        .CLKA(clock),.CLKB(clock),.CEA(write_a_i||read_a_i),.CEB(write_b_i||read_b_i),
        .WEA(write_a_i),.WEB(write_b_i),.CSA(3'b000),.CSB(3'b000),
        .ADDRA({1'b1,1'b0,address_a,5'b0}),.ADDRB({1'b1,1'b1,address_b,5'b0}),
        .ADDRA_HOLD(1'b0),.ADDRB_HOLD(1'b0),.BWEA(8'hff),.BWEB(4'hf),
        .DIA({1'b0,write_data_a_i[31:24],1'b0,write_data_a_i[23:16],
              1'b0,write_data_a_i[15:8],1'b0,write_data_a_i[7:0]}),
        .DIB({1'b0,write_data_b_i[31:24],1'b0,write_data_b_i[23:16],
              1'b0,write_data_b_i[15:8],1'b0,write_data_b_i[7:0]}),
        .DOA(qa),.DOB(qb),.ORCEA(1'b1),.ORCEB(1'b1),.RSTA(!reset_n),.RSTB(!reset_n),
        .CINA(1'b0),.CINB(1'b0),.INJECT_SBITERR(1'b0),.INJECT_DBITERR(1'b0),
        .ECC_SBITERR(),.ECC_DBITERR(),.ECC_RDADDR(),.ECC_PARITY(),.COUTA(),.COUTB());
endmodule
