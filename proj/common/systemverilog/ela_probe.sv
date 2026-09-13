// -------------------------------------------------------------------------
// COPYRIGHT © 2026, BRISBANE SILICON, PTY LTD.
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
// DESCRIPTION :
//
//  Embedded Logic Analyzer probe. Only built with 'build -e'.
//
// -------------------------------------------------------------------------
// SPECIFICATION :
//
//  Every bit of 'probe' can be captured over JTAG with fcapz. The names
//  of those bits are in 'ela_probe.prob' - keep the two in step.
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module ela_probe #(
    parameter int   DEPTH = 1024
) (
    input           clk,
    input           resetn,


    // -------------- bus transactions --------------

    input   [31:0]  bus_addr,
    input   [31:0]  bus_data,
    input           bus_write,
    input           bus_done,


    // -------------- bus pins, synchronised by cpu_bus --------------

    input   [15:0]  pin_data,
    input           pin_clk,
    input           pin_wr,


    // -------------- user --------------

    input   [15:0]  user_probe,


    // -------------- jtag --------------

    input           tms,
    input           tck,
    input           tdi,
    output          tdo
);

    localparam int  PROBE_W = 100;


    wire [PROBE_W-1:0] probe = {
        user_probe,         // [99:84]
        bus_data,           // [83:52]
        bus_addr,           // [51:20]
        pin_data,           // [19:4]
        pin_wr,             // [3]
        pin_clk,            // [2]
        bus_write,          // [1]
        bus_done            // [0]
    };


    // NOTE: register the whole probe, so the
    // analyzer's logic starts from flip-flops
    // and stays off the design's timing paths...

    reg     [PROBE_W-1:0]   i_probe;

    always @(posedge clk) begin
        i_probe <= probe;
    end


    fcapz_ela_gowin #(
        .SAMPLE_W       (PROBE_W),
        .DEPTH          (DEPTH),
        .STOR_QUAL      (1)
            // NOTE: lets fcapz store only the
            // samples asked for, e.g. one per
            // transaction...
            //
            // NOTE: leave INPUT_PIPE at its default
            // of 0. Above that, fcapz stores the
            // sample one clk after the one that
            // matched, so one clk pulses such as
            // 'bus_done' read back as 0. The
            // 'i_probe' register handles timing...
    ) fcapz_ela_gowin_inst (
        .clk            (clk),
        .jtag_activity  (),

        .sample_clk     (clk),
        .sample_rst     (~resetn),
        .probe_in       (i_probe),

        .eio_probe_in   (1'b0),
        .eio_probe_out  (),

        .tms_pad_i      (tms),
        .tck_pad_i      (tck),
        .tdi_pad_i      (tdi),
        .tdo_pad_o      (tdo)
    );

endmodule
