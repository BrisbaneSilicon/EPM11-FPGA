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
// DESCRIPTION : Flip-flop chain for bringing an asynchronous signal into
//               the 'clk' domain. Depth is set by pSYNC_STAGES, so it can
//               be increased without touching any instantiation logic.
//
// -------------------------------------------------------------------------
// USE CASE(S) : Any single-bit signal crossing into 'clk' from another
//               domain or from a pad - see busV2 and cpu_watch.
//
// -------------------------------------------------------------------------
// NOTE : This mirrors fpgacapZero's rtl/dff_sync.v, which Brisbane Silicon
//        authored upstream. It is kept as a separate module rather than
//        used directly because build.tcl adds that file to every '-e'
//        build, and two modules sharing one name is a hard synthesis
//        error. The 'bs_' prefix keeps ours distinct while the interface
//        and behaviour stay identical, so the two are interchangeable.
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module bs_dff_sync
#(
    parameter int pSYNC_STAGES  = 2,
        // NOTE: minimum 2; this is the total
        // number of sync flops.
    parameter bit pSYNC_DEFAULT = 1'b0
)
(
    // ------ 'clk' synchronous ------

    input   logic   clk,
    input   logic   srst,
    output  logic   sync,

    // ------ asynchronous ------

    input   logic   async
);

    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    logic [pSYNC_STAGES-1:0]    i_sync_stages;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    assign sync = i_sync_stages[pSYNC_STAGES-1];

    always @(posedge clk) begin

        i_sync_stages <= {i_sync_stages[pSYNC_STAGES-2:0], async};

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            i_sync_stages <= {pSYNC_STAGES{pSYNC_DEFAULT}};
        end
    end

endmodule
