// -------------------------------------------------------------------------
// COPYRIGHT © 2025, BRISBANE SILICON, PTY LTD.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROVIDED ON AN "AS IS" BASIS.
// BRISBANE SILICON, PTY LTD. DISCLAIMS ANY AND ALL WARRANTIES,
// WHETHER EXPRESS, IMPLIED, OR STATUTORY, INCLUDING ANY IMPLIED
// WARRANTIES OF MERCHANTABILITY OR OF FITNESS FOR A PARTICULAR PURPOSE.
// IN NO EVENT SHALL BRISBANE SILICON, PTY LTD. BE LIABLE FOR ANY
// INCIDENTAL, PUNITIVE, OR CONSEQUENTIAL DAMAGES OF ANY KIND WHATSOEVER
// ARISING FROM THE USE OF THIS SOURCE CODE.
//
// THIS DISCLAIMER OF WARRANTY EXTENDS TO THE USER OF THIS SOURCE CODE
// AND USER'S CUSTOMERS, EMPLOYEES, AGENTS, TRANSFEREES, SUCCESSORS,
// AND ASSIGNS.
//
// THIS IS NOT A GRANT OF PATENT RIGHTS
//
// -------------------------------------------------------------------------
// DESCRIPTION : Synchroniser with edge detection. Wraps bs_dff_sync and
//               adds one-clk pulses on the rising, falling and either
//               edge of the synchronised signal.
//
// -------------------------------------------------------------------------
// USE CASE(S) : Recovering clean single-cycle events from a slow external
//               strobe - see busV2, where the host's pclk is turned into
//               'rise' and 'fall' ticks.
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module sync_edge
#(
    parameter int pSYNC_STAGES  = 2,
    parameter bit pSYNC_DEFAULT = 1'b0
)
(
    // ------ 'clk' synchronous ------

    input   logic   clk,
    input   logic   srst,

    output  logic   sync,
    output  logic   rise,
        // NOTE: one clk pulse on the rising edge
    output  logic   fall,
        // NOTE: one clk pulse on the falling edge
    output  logic   edge_any,
        // NOTE: one clk pulse on either edge

    // ------ asynchronous ------

    input   logic   async
);

    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    logic   i_sync_d;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    bs_dff_sync #(
        .pSYNC_STAGES   (pSYNC_STAGES),
        .pSYNC_DEFAULT  (pSYNC_DEFAULT)
    ) bs_dff_sync_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (sync),

        .async          (async)
    );

    always @(posedge clk) begin

        i_sync_d <= sync;

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            i_sync_d <= pSYNC_DEFAULT;
        end
    end

    assign rise     = sync & ~i_sync_d;
    assign fall     = ~sync & i_sync_d;
    assign edge_any = sync ^ i_sync_d;

endmodule
