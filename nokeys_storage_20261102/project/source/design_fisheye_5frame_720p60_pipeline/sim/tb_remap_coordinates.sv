`timescale 1ns/1ps

module tb_remap_coordinates;
    localparam integer ANCHOR_COLUMNS = 121;
    localparam integer ANCHOR_COUNT = 8349;

    logic clock = 0;
    always #4 clock = ~clock;

    logic reset_n = 0;
    logic input_valid = 0;
    logic [10:0] output_x = 0;
    logic [10:0] output_y = 0;
    logic corrected_valid;
    logic [19:0] source_x_q8;
    logic [19:0] source_y_q8;
    logic neighborhood_valid;

    logic [39:0] reference_anchors [0:ANCHOR_COUNT-1];
    logic [19:0] expected_x [0:6];
    logic [19:0] expected_y [0:6];
    logic expected_valid [0:6];
    logic expected_bounds [0:6];
    logic [19:0] current_x;
    logic [19:0] current_y;
    logic current_bounds;
    integer checks = 0;

    remap_coordinates #(
        .ANCHOR_FILE("source/design_fisheye_5frame_live/data/map_anchor.mem")
    ) device_under_test (
        .clock(clock),
        .reset_n(reset_n),
        .cal_write_en_i(1'b0), .cal_table_select_i(1'b0),
        .cal_write_addr_i(14'd0), .cal_write_data_i(48'd0),
        .output_valid_i(input_valid),
        .output_x(output_x),
        .output_y(output_y),
        .source_valid_o(corrected_valid),
        .source_x_q8(source_x_q8),
        .source_y_q8(source_y_q8),
        .neighborhood_valid_o(neighborhood_valid)
    );

    function automatic [19:0] blend16(
        input [19:0] left_value,
        input [19:0] right_value,
        input [3:0] fraction
    );
        reg [24:0] sum;
        begin
            sum = left_value * (16 - fraction)
                + right_value * fraction + 8;
            blend16 = sum >> 4;
        end
    endfunction

    task automatic reference_point(
        input [10:0] x,
        input [10:0] y,
        output [19:0] source_x,
        output [19:0] source_y,
        output bounds_valid
    );
        integer index;
        reg [19:0] upper_x, lower_x, upper_y, lower_y;
        begin
            index = (y >> 4) * ANCHOR_COLUMNS + (x >> 4);
            upper_x = blend16(reference_anchors[index][19:0],
                              reference_anchors[index + 1][19:0], x[3:0]);
            lower_x = blend16(reference_anchors[index + ANCHOR_COLUMNS][19:0],
                              reference_anchors[index + ANCHOR_COLUMNS + 1][19:0], x[3:0]);
            upper_y = blend16(reference_anchors[index][39:20],
                              reference_anchors[index + 1][39:20], x[3:0]);
            lower_y = blend16(reference_anchors[index + ANCHOR_COLUMNS][39:20],
                              reference_anchors[index + ANCHOR_COLUMNS + 1][39:20], x[3:0]);
            source_x = blend16(upper_x, lower_x, y[3:0]);
            source_y = blend16(upper_y, lower_y, y[3:0]);
            bounds_valid = source_x[19:8] < 1919
                        && source_y[19:8] < 1079;
        end
    endtask

    always @(posedge clock) begin
        if (!reset_n) begin
            for (integer stage = 0; stage < 7; stage = stage + 1) begin
                expected_valid[stage] <= 0;
                expected_bounds[stage] <= 0;
            end
        end else begin
            reference_point(output_x, output_y,
                            current_x, current_y, current_bounds);
            expected_valid[0] <= input_valid;
            expected_x[0] <= current_x;
            expected_y[0] <= current_y;
            expected_bounds[0] <= current_bounds;
            for (integer stage = 1; stage < 7; stage = stage + 1) begin
                expected_valid[stage] <= expected_valid[stage - 1];
                expected_x[stage] <= expected_x[stage - 1];
                expected_y[stage] <= expected_y[stage - 1];
                expected_bounds[stage] <= expected_bounds[stage - 1];
            end
            #1;
            if (corrected_valid !== expected_valid[6])
                $fatal(1, "remap valid pipeline mismatch");
            if (expected_valid[6]) begin
                if (source_x_q8 !== expected_x[6] || source_y_q8 !== expected_y[6]
                    || neighborhood_valid !== expected_bounds[6])
                    $fatal(1, "remap mismatch: got (%0d,%0d), expected (%0d,%0d)",
                           source_x_q8, source_y_q8, expected_x[6], expected_y[6]);
                checks = checks + 1;
            end
        end
    end

    initial begin
        $readmemh("source/design_fisheye_5frame_live/data/map_anchor.mem", reference_anchors);
        repeat (4) @(negedge clock);
        reset_n = 1;
        for (integer index = 0; index < 1024; index = index + 1) begin
            @(negedge clock);
            input_valid = 1;
            output_x = (index * 487 + 1919) % 1920;
            output_y = (index * 313 + 1079) % 1080;
        end
        @(negedge clock);
        input_valid = 0;
        repeat (9) @(negedge clock);
        if (checks != 1024)
            $fatal(1, "remap checked %0d pixels instead of 1024", checks);
        $display("PASS tb_remap_coordinates: %0d pixels", checks);
        $finish;
    end
endmodule
