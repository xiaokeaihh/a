`timescale 1ns/1ps

module tb_frame_bank_manager;
    reg clock = 0;
    always #5 clock = ~clock;
    reg reset_n = 0;
    reg camera_frame_start_i = 0;
    reg camera_frame_end_i = 0;
    reg camera_frame_complete_i = 0;
    reg render_request_i = 0;
    reg render_done_i = 0;
    reg render_failed_i = 0;
    reg hdmi_frame_start_i = 0;
    wire camera_accept_o;
    wire camera_drop_o;
    wire camera_write_active_o;
    wire [1:0] camera_write_bank_o;
    wire render_grant_o;
    wire render_active_o;
    wire [1:0] render_source_bank_o;
    wire [1:0] render_destination_bank_o;
    wire display_valid_o;
    wire [1:0] display_bank_o;

    frame_bank_manager dut (.*);

    task automatic step(
        input bit camera_start, input bit camera_end,
        input bit camera_complete, input bit render_request,
        input bit render_done, input bit hdmi_start
    );
        begin
            @(negedge clock);
            camera_frame_start_i = camera_start;
            camera_frame_end_i = camera_end;
            camera_frame_complete_i = camera_complete;
            render_request_i = render_request;
            render_done_i = render_done;
            hdmi_frame_start_i = hdmi_start;
            @(posedge clock);
            #1;
            if (camera_write_active_o && render_active_o
                && camera_write_bank_o == render_source_bank_o)
                $fatal(1, "raw bank read/write collision");
            if (display_valid_o && render_active_o
                && display_bank_o == render_destination_bank_o)
                $fatal(1, "corrected bank read/write collision");
        end
    endtask

    initial begin
        repeat (3) @(negedge clock);
        reset_n = 1;
        step(1, 0, 0, 0, 0, 0);
        if (!camera_accept_o || camera_write_bank_o != 0) $fatal(1, "raw bank 0 not allocated");
        step(0, 1, 1, 0, 0, 0);
        step(0, 0, 0, 1, 0, 0);
        if (!render_grant_o || render_source_bank_o != 0
            || render_destination_bank_o != 0) $fatal(1, "render 0 not granted");
        step(1, 0, 0, 0, 0, 0);
        if (!camera_accept_o || camera_write_bank_o != 1) $fatal(1, "raw bank 1 not allocated");
        step(0, 1, 1, 0, 0, 0);
        step(0, 0, 0, 0, 1, 0);
        step(0, 0, 0, 0, 0, 1);
        if (!display_valid_o || display_bank_o != 0) $fatal(1, "display 0 not selected");
        step(0, 0, 0, 1, 0, 0);
        if (!render_grant_o || render_source_bank_o != 1
            || render_destination_bank_o != 1) $fatal(1, "render 1 not granted");
        step(1, 0, 0, 0, 0, 0);
        if (!camera_accept_o || camera_write_bank_o != 0) $fatal(1, "reused raw bank wrong");
        step(1, 0, 0, 0, 0, 0);
        if (!camera_drop_o || camera_accept_o) $fatal(1, "overlapping camera frame not dropped");
        step(0, 1, 0, 0, 0, 0);
        step(0, 0, 0, 0, 1, 0);
        step(0, 0, 0, 0, 0, 1);
        if (!display_valid_o || display_bank_o != 1) $fatal(1, "display 1 not selected");
        step(1, 0, 0, 0, 0, 0);
        step(0, 1, 1, 0, 0, 0);
        step(1, 0, 0, 0, 0, 0);
        step(0, 1, 1, 0, 0, 0);
        step(0, 0, 0, 1, 0, 0);
        if (!render_grant_o || render_source_bank_o != 1)
            $fatal(1, "latest complete raw frame not selected");
        render_failed_i = 1;
        step(0, 0, 0, 0, 0, 0);
        render_failed_i = 0;
        if (render_active_o || display_bank_o != 1)
            $fatal(1, "failed render was published or bank not released");
        $display("PASS tb_frame_bank_manager: raw/corrected bank switching");
        $finish;
    end
endmodule
