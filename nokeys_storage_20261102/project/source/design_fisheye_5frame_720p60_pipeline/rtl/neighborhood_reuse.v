`timescale 1ns/1ps
// Direct-mapped 4x4 window slots indexed by global {y[1:0],x[1:0]}.
// Predicted tags include in-flight reads. Finish tokens commit after the fixed
// three-edge cache response, before any later token can overwrite its samples.
module neighborhood_reuse (
    input wire clock,reset_n,row_start_i,tile_start_i,
    input wire input_valid_i,
    output wire input_ready_o,
    input wire [19:0] source_x_q8_i,source_y_q8_i,
    input wire source_inside_i,
    input wire [8:0] radial_blend_i,
    output wire [3:0] bank_read_valid_o,
    output wire [43:0] bank_read_x_flat_o,bank_read_y_flat_o,
    input wire [3:0] bank_return_valid_i,
    input wire [63:0] bank_return_pixels_i,
    output reg pixel_valid_o,neighborhood_valid_o,
    output reg [255:0] source_pixels_flat_o,
    output reg [7:0] fractional_x_o,fractional_y_o,
    output reg [8:0] radial_blend_o,
    output reg error_o
);
    reg active_job;
    reg [49:0] job;
    reg [15:0] remaining;
    reg [15:0] predicted_valid;
    reg [8:0] tag_x [0:15],tag_y [0:15];
    reg [15:0] window_pixels [0:15];
    wire [49:0] descriptor=active_job?job:{source_inside_i,radial_blend_i,source_y_q8_i,source_x_q8_i};
    wire [19:0] xq=descriptor[19:0],yq=descriptor[39:20];
    wire [8:0] blend=descriptor[48:40];
    wire expand=blend!=0;
    wire source_in_bounds=descriptor[49] && xq[19:8]<1279 && yq[19:8]<719
               && (!expand || (xq[19:8]>=1 && yq[19:8]>=1 && xq[19:8]<1278 && yq[19:8]<718));
    wire [11:0] left=xq[19:8]-12'd1,top=yq[19:8]-12'd1;
    wire schedule=reset_n && !row_start_i && (active_job || input_valid_i);
    assign input_ready_o=!active_job && reset_n && !row_start_i;
    wire [11:0] target_x [0:15],target_y [0:15];
    wire [15:0] missing;
    wire [15:0] to_issue=source_in_bounds?(active_job?remaining:missing):16'd0;
    wire [15:0] selected_mask;
    wire [15:0] not_issued=to_issue & ~selected_mask;
    wire finish=schedule && not_issued==0;
    reg [15:0] return_mask0,return_mask1,return_mask2;
    reg [2:0] finish_pipe;
    reg [49:0] descriptor0,descriptor1,descriptor2;
    wire [15:0] effective_pixel [0:15];
    genvar slot,bank;
    generate
        for(slot=0;slot<16;slot=slot+1) begin: slots
            localparam integer X_MOD=slot%4,Y_MOD=slot/4;
            localparam integer BANK=(Y_MOD%2)*2+(X_MOD%2);
            wire [1:0] dx=X_MOD-left[1:0],dy=Y_MOD-top[1:0];
            assign target_x[slot]=left+{10'd0,dx};
            assign target_y[slot]=top+{10'd0,dy};
            wire desired=expand || ((dx==1 || dx==2) && (dy==1 || dy==2));
            assign missing[slot]=desired && (!predicted_valid[slot]
                || tag_x[slot]!=target_x[slot][10:2] || tag_y[slot]!=target_y[slot][10:2]);
            assign effective_pixel[slot]=return_mask2[slot] && bank_return_valid_i[BANK]
                ?bank_return_pixels_i[BANK*16+:16]:window_pixels[slot];
        end
        for(bank=0;bank<4;bank=bank+1) begin: priorities
            localparam integer S0=(bank/2)*4+(bank%2),S1=S0+2,S2=S0+8,S3=S0+10;
            // Exactly the previous S0 > S1 > S2 > S3 order, expressed as
            // one-hot picks. Each bank has only two distinct X and Y values;
            // avoid indexing a 16-entry coordinate array with a 4-bit mux.
            wire pick0=to_issue[S0];
            wire pick1=to_issue[S1] && !to_issue[S0];
            wire pick2=to_issue[S2] && !(to_issue[S0] || to_issue[S1]);
            wire pick3=to_issue[S3] && !(to_issue[S0] || to_issue[S1] || to_issue[S2]);
            assign selected_mask[S0]=schedule && pick0;
            assign selected_mask[S1]=schedule && pick1;
            assign selected_mask[S2]=schedule && pick2;
            assign selected_mask[S3]=schedule && pick3;
            assign bank_read_valid_o[bank]=schedule && (to_issue[S0] || to_issue[S1] || to_issue[S2] || to_issue[S3]);
            assign bank_read_x_flat_o[bank*11+:11]=(pick1 || pick3)?target_x[S1][10:0]:target_x[S0][10:0];
            assign bank_read_y_flat_o[bank*11+:11]=(pick2 || pick3)?target_y[S2][10:0]:target_y[S0][10:0];
        end
    endgenerate
    wire [3:0] expected_returns={| (return_mask2&16'ha0a0),| (return_mask2&16'h5050),| (return_mask2&16'h0a0a),| (return_mask2&16'h0505)};
    integer s,r,c;
    reg [1:0] sx,sy;
    always @(posedge clock) begin
        if(!reset_n || row_start_i || tile_start_i) begin
            active_job<=0;remaining<=0;
            if(!reset_n || tile_start_i) predicted_valid<=0;
            return_mask0<=0;return_mask1<=0;return_mask2<=0;finish_pipe<=0;
            pixel_valid_o<=0;neighborhood_valid_o<=0;error_o<=0;
        end else begin
            return_mask0<=selected_mask;return_mask1<=return_mask0;return_mask2<=return_mask1;
            finish_pipe<={finish_pipe[1:0],finish};
            pixel_valid_o<=finish_pipe[2];
            if(bank_return_valid_i!=expected_returns) error_o<=1;
            if(schedule) begin
                if(!active_job) job<=descriptor;
                active_job<=not_issued!=0;
                remaining<=not_issued;
            end
            // Fixed-delay metadata payload; finish_pipe alone qualifies use.
            // Do not drive 50-bit payload CE with the full tag/missing reduction.
            // Only payload on a finish token is observable three edges later.
            descriptor0<={source_in_bounds,descriptor[48:0]};
            descriptor1<=descriptor0;
            descriptor2<=descriptor1;
            for(s=0;s<16;s=s+1) begin
                if(selected_mask[s]) begin
                    predicted_valid[s]<=1;tag_x[s]<=target_x[s][10:2];tag_y[s]<=target_y[s][10:2];
                end
                if(return_mask2[s]) window_pixels[s]<=effective_pixel[s];
            end
            if(finish_pipe[2]) begin
                fractional_x_o<=descriptor2[7:0];fractional_y_o<=descriptor2[27:20];radial_blend_o<=descriptor2[48:40];
                neighborhood_valid_o<=descriptor2[49];
                for(r=0;r<4;r=r+1) for(c=0;c<4;c=c+1) begin
                    sx=descriptor2[9:8]-2'd1+c;
                    sy=descriptor2[29:28]-2'd1+r;
                    source_pixels_flat_o[(r*4+c)*16+:16]<=effective_pixel[{sy,sx}];
                end
            end
        end
    end
endmodule
