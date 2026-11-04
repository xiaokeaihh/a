`timescale 1ns/1ps

// Passive DDR-domain observer. No WVALID exists on this vendor interface:
// accepted AW ownership plus WREADY defines each accepted camera data beat.
module capture_beat_tap #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720,
    parameter integer FRAME_ADDRESS_BITS = 19
) (
    input wire clock,
    input wire reset_n,
    input wire awvalid_i,
    input wire awready_i,
    input wire [27:0] awaddr_i,
    input wire [3:0] awlen_i,
    input wire [31:0] frame_id_i,
    input wire wready_i,
    input wire wlast_i,
    input wire [255:0] wdata_i,
    output reg valid_o,
    output reg [31:0] frame_id_o,
    output reg [1:0] source_bank_o,
    output reg [10:0] source_x_o,
    output reg [10:0] source_y_o,
    output reg [255:0] pixels_o,
    output reg error_o
);
    localparam integer ROW_WORDS = IMAGE_WIDTH / 2;
    localparam integer FRAME_WORDS = ROW_WORDS * IMAGE_HEIGHT;
    wire accept_address = awvalid_i && awready_i;
    wire [FRAME_ADDRESS_BITS-1:0] word_offset = awaddr_i[FRAME_ADDRESS_BITS-1:0];
    wire [1:0] address_bank = awaddr_i[FRAME_ADDRESS_BITS+:2];
    wire [10:0] address_row;
    wire [11:0] address_column;
    generate if(IMAGE_WIDTH==1280 && FRAME_ADDRESS_BITS==19)begin: factor_row_stride
        // 640=5*128: only twelve upper address bits enter the divide-by-five.
        // The lower seven bits bypass it unchanged, including invalid addresses.
        wire [11:0] row_group=word_offset[18:7];
        wire [2:0] group_remainder=row_group%12'd5;
        assign address_row=row_group/12'd5;
        assign address_column={1'b0,group_remainder,word_offset[6:0],1'b0};
    end else begin: generic_row_stride
        assign address_row=word_offset/ROW_WORDS;
        assign address_column=(word_offset%ROW_WORDS)*2;
    end endgenerate
    wire [4:0] address_beats = {1'b0, awlen_i} + 5'd1;
    wire address_invalid = (awaddr_i[27:FRAME_ADDRESS_BITS+2] != 0) ||
                           address_bank >= 3 || word_offset >= FRAME_WORDS ||
                           word_offset[2:0] != 0 ||
                           address_column + (address_beats << 4) > IMAGE_WIDTH;

    reg transaction_active;
    reg transaction_invalid;
    reg [4:0] remaining_beats;
    reg [31:0] transaction_frame;
    reg [1:0] transaction_bank;
    reg [10:0] current_x;
    reg [10:0] current_y;
    wire last_mismatch = wlast_i != (remaining_beats == 1);

    always @(posedge clock) begin
        if (!reset_n) begin
            transaction_active <= 1'b0;
            transaction_invalid <= 1'b0;
            remaining_beats <= 0;
            transaction_frame <= 0;
            transaction_bank <= 0;
            current_x <= 0;
            current_y <= 0;
            valid_o <= 1'b0;
            frame_id_o <= 0;
            source_bank_o <= 0;
            source_x_o <= 0;
            source_y_o <= 0;
            pixels_o <= 0;
            error_o <= 1'b0;
        end else begin
            valid_o <= 1'b0;
            if (accept_address) begin
                if (transaction_active) begin
                    error_o <= 1'b1;
                    transaction_invalid <= 1'b1;
                end else begin
                    transaction_active <= 1'b1;
                    transaction_invalid <= address_invalid;
                    remaining_beats <= address_beats;
                    transaction_frame <= frame_id_i;
                    transaction_bank <= address_bank;
                    current_x <= address_column[10:0];
                    current_y <= address_row;
                    if (address_invalid) error_o <= 1'b1;
                end
            end
            if (wready_i && transaction_active) begin
                if (last_mismatch) begin
                    error_o <= 1'b1;
                    transaction_invalid <= 1'b1;
                end
                if (!transaction_invalid && !last_mismatch && !accept_address) begin
                    valid_o <= 1'b1;
                    frame_id_o <= transaction_frame;
                    source_bank_o <= transaction_bank;
                    source_x_o <= current_x;
                    source_y_o <= current_y;
                    pixels_o <= wdata_i;
                end
                if (remaining_beats == 1) begin
                    transaction_active <= 1'b0;
                    remaining_beats <= 0;
                end else begin
                    remaining_beats <= remaining_beats - 1'b1;
                    current_x <= current_x + 11'd16;
                end
            end
        end
    end
endmodule
