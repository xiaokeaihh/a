`timescale 1ns/1ps

// Shared 16x2 source blocks. Each parity bank stores eight pixels per row.
// Frame-locked row/column-major indexing follows the source sweep direction.
// Tags hold the upper key; index plus tag still identifies the complete key.
module shared_source_pool #(
    parameter integer SLOT_BITS = 9
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
    input wire [31:0] lookup_frame_i,
    input wire [1:0] lookup_bank_i,
    input wire [10:0] lookup_x_i, lookup_y_i,
    output reg lookup_valid_o,
    output reg hit_o,
    output reg [3:0] miss_mask_o,
    output reg [63:0] pixels_o,
    output reg error_o
);
    localparam integer SLOTS = 1 << SLOT_BITS;
    localparam integer TAG_BITS = 15 - SLOT_BITS;
    reg [31:0] active_frame;
    reg [1:0] active_bank;
    reg active_column_major;

    function [14:0] source_key;
        input [10:0] x, y;
        input column_major;
        reg [14:0] pair_row, block_column;
        begin
            pair_row = y >> 1;
            block_column = x >> 4;
            source_key = column_major ? (block_column << 8) + (block_column << 6) +
                         (block_column << 5) + (block_column << 3) + pair_row :
                         (pair_row << 6) + (pair_row << 4) + block_column;
        end
    endfunction

    function [SLOT_BITS-1:0] slot_index;
        input [14:0] key;
        begin
            slot_index = key[SLOT_BITS-1:0];
        end
    endfunction

    wire [14:0] fill_key = source_key(fill_x_i, fill_y_i, active_column_major);
    wire [SLOT_BITS-1:0] fill_slot = slot_index(fill_key);
    wire fill_identity_matches = fill_frame_i == active_frame && fill_bank_i == active_bank;
    wire fill_coordinates_valid = fill_x_i < 1280 && fill_x_i[3:0] == 0 && fill_y_i < 720;
    wire lookup_identity_matches = lookup_frame_i == active_frame && lookup_bank_i == active_bank;
    wire lookup_coordinates_valid = lookup_x_i < 1279 && lookup_y_i < 719;
    wire [4*SLOT_BITS-1:0] request_slots;
    wire [3:0] bank_hits;
    wire [63:0] bank_pixels;
    reg token_d1, token_d2;
    reg [4*SLOT_BITS-1:0] slots_d1, slots_d2;
    reg [3:0] hits_d2;
    reg [1:0] origin_d1, origin_d2;
    reg fill_conflict;
    integer bank_number;

    always @* begin
        fill_conflict = 1'b0;
        for (bank_number = 0; bank_number < 4; bank_number = bank_number + 1) begin
            if (fill_y_i[0] == bank_number / 2) begin
                if (lookup_valid_i && lookup_identity_matches && lookup_coordinates_valid &&
                    request_slots[bank_number*SLOT_BITS+:SLOT_BITS] == fill_slot)
                    fill_conflict = 1'b1;
                if (token_d1 && slots_d1[bank_number*SLOT_BITS+:SLOT_BITS] == fill_slot)
                    fill_conflict = 1'b1;
                if (token_d2 && slots_d2[bank_number*SLOT_BITS+:SLOT_BITS] == fill_slot)
                    fill_conflict = 1'b1;
            end
        end
    end
    assign fill_ready_o = reset_n && !frame_start_i && fill_identity_matches &&
                          fill_coordinates_valid && !fill_conflict;
    wire accept_fill = fill_valid_i && fill_ready_o;

    genvar bank, pixel;
    generate for (bank = 0; bank < 4; bank = bank + 1) begin: banks
        wire [10:0] request_x = lookup_x_i + (lookup_x_i[0] != bank % 2);
        wire [10:0] request_y = lookup_y_i + (lookup_y_i[0] != bank / 2);
        wire [14:0] request_key = source_key(request_x, request_y, active_column_major);
        wire [SLOT_BITS-1:0] request_slot = slot_index(request_key);
        assign request_slots[bank*SLOT_BITS+:SLOT_BITS] = request_slot;
        reg [TAG_BITS-1:0] tags[0:SLOTS-1] /* synthesis syn_ramstyle="block_ram" */;
        reg [SLOTS-1:0] occupied;
        reg [TAG_BITS-1:0] tag_d1, expected_d1;
        reg eligible_d1;
        reg [SLOT_BITS+2:0] pixel_address_d1;
        wire [127:0] fill_word;
        wire bank_fill = accept_fill && fill_y_i[0] == bank / 2;
        for (pixel = 0; pixel < 8; pixel = pixel + 1) begin: pack
            assign fill_word[pixel*16+:16] = fill_pixels_i[(pixel*2+bank%2)*16+:16];
        end
        assign bank_hits[bank] = eligible_d1 && tag_d1 == expected_d1;

        always @(posedge clock) begin
            if (bank_fill) tags[fill_slot] <= fill_key[14:SLOT_BITS];
            if (lookup_valid_i) begin
                tag_d1 <= tags[request_slot];
                expected_d1 <= request_key[14:SLOT_BITS];
                pixel_address_d1 <= {request_slot, request_x[3:1]};
            end
            if (!reset_n || frame_start_i) begin
                occupied <= 0;
                eligible_d1 <= 1'b0;
            end else begin
                if (bank_fill) occupied[fill_slot] <= 1'b1;
                eligible_d1 <= lookup_valid_i && lookup_identity_matches &&
                               lookup_coordinates_valid && occupied[request_slot];
            end
        end

        // Reuse the existing 2022.2 vendor RAM module unchanged, with new parameters.
        ipm2l_sdpram_v1_10_wr_fram_buf #(
            .c_CAS_MODE("36K"), .c_WR_ADDR_WIDTH(SLOT_BITS), .c_WR_DATA_WIDTH(128),
            .c_RD_ADDR_WIDTH(SLOT_BITS+3), .c_RD_DATA_WIDTH(16), .c_OUTPUT_REG(0),
            .c_WR_CLK_EN(1), .c_RD_CLK_EN(1), .c_RESET_TYPE("SYNC")
        ) data_ram (
            .wr_addr(fill_slot), .wr_data(fill_word), .wr_en(bank_fill),
            .wr_clk(clock), .wr_clk_en(bank_fill), .wr_rst(!reset_n),
            .wr_byte_en(8'hff), .wr_addr_strobe(1'b0),
            .rd_addr(pixel_address_d1), .rd_data(bank_pixels[bank*16+:16]),
            .rd_clk(clock), .rd_clk_en(token_d1 && bank_hits[bank]),
            .rd_rst(!reset_n), .rd_oce(1'b1), .rd_addr_strobe(1'b0)
        );
    end endgenerate

    always @(posedge clock) begin
        if (!reset_n || frame_start_i) begin
            token_d1 <= 0; token_d2 <= 0; lookup_valid_o <= 0;
            hit_o <= 0; miss_mask_o <= 4'hf; pixels_o <= 0;
            error_o <= 0;
            if (!reset_n) begin active_frame <= 0; active_bank <= 0; active_column_major <= 0; end
            else begin active_frame <= frame_id_i; active_bank <= source_bank_i; active_column_major <= column_major_i; end
        end else begin
            token_d1 <= lookup_valid_i;
            token_d2 <= token_d1;
            lookup_valid_o <= token_d2;
            if (lookup_valid_i) begin
                slots_d1 <= request_slots;
                origin_d1 <= {lookup_y_i[0], lookup_x_i[0]};
            end
            if (token_d1) begin
                hits_d2 <= bank_hits;
                slots_d2 <= slots_d1;
                origin_d2 <= origin_d1;
            end
            if (token_d2) begin
                miss_mask_o <= ~hits_d2;
                hit_o <= &hits_d2;
                pixels_o <= (&hits_d2) ? {
                    bank_pixels[(origin_d2 ^ 2'd3)*16+:16],
                    bank_pixels[(origin_d2 ^ 2'd2)*16+:16],
                    bank_pixels[(origin_d2 ^ 2'd1)*16+:16],
                    bank_pixels[origin_d2*16+:16]} : 64'd0;
            end
            if (fill_valid_i && fill_identity_matches && !fill_coordinates_valid)
                error_o <= 1'b1;
        end
    end
endmodule
