`timescale 1ns/1ps

module dff_synchroniser #(
    parameter SYNC_STAGES   = 2,
    parameter SYNC_DEFAULT  = 1'b0
) (
    // ------ 'clk' synchronous ------
    input       clk,
    input       srst,
    output wire sync,

    // ------ asynchronous ------
    input       async
);

    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    reg [SYNC_STAGES-1:0] i_sync_stages;


    // ----------------------------------------------
    //  Validate Configuration
    // ----------------------------------------------

    generate
        if (SYNC_STAGES < 2) begin : g_invalid_sync_stages
            initial begin
                $error("dff_sync: SYNC_STAGES must be >= 2");
                $finish;
            end
        end
    endgenerate


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    assign sync = i_sync_stages[SYNC_STAGES-1];

    always @(posedge clk) begin
        if (srst == 1'b1) begin
            i_sync_stages <= {SYNC_STAGES{SYNC_DEFAULT}};
        end else begin
            i_sync_stages <= {i_sync_stages[SYNC_STAGES-2:0], async};
        end
    end

endmodule