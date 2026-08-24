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
// DESCRIPTION : Host bus slave, write only. Superseded by busV2, which
//               adds the read direction. Kept for reference.
//
// -------------------------------------------------------------------------
// SPECIFICATION :
//
// A write burst is 4 cpu_clk cycles:
//   beat 0 : addr [15:0]
//   beat 1 : addr [31:16]
//   beat 2 : data [15:0]
//   beat 3 : data [31:16]
//
// cpu_wr high frames the burst - the host raises it before beat 0 and
// drops it after beat 3.
//
// Nothing here ever drives the data lines, so they are a plain input
// rather than a tri-state we would only ever park at 'z'.
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module bus
#(
    parameter int pSYNC_STAGES = 2
)
(
    // ---------------- clocking ----------------

    input   logic           clk,
    input   logic           srst,

    // ---------------- host bus, asynchronous ----------------

    input   logic   [15:0]  cpu_data_async,
    input   logic           cpu_clk_async,
    input   logic           cpu_wr_async,

    // ---------------- fabric master ----------------

    output  logic   [31:0]  m_addr,
    output  logic   [31:0]  m_wrdata,
    output  logic           m_wvalid
        // NOTE: one clk strobe, burst complete
);

    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    logic           i_cpu_clk_sync;
    logic           i_cpu_clk_rise;
    logic           i_cpu_wr_sync;

    logic   [1:0]   i_beat;
    logic           i_frame_done;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    sync_edge #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) sync_edge_cpu_clk_inst (
        .clk            (clk),
        .srst           (srst),

        .sync           (i_cpu_clk_sync),
        .rise           (i_cpu_clk_rise),
        .fall           (),
        .edge_any       (),

        .async          (cpu_clk_async)
    );

    bs_dff_sync #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) bs_dff_sync_cpu_wr_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (i_cpu_wr_sync),

        .async          (cpu_wr_async)
    );

    always @(posedge clk) begin

        m_wvalid <= 1'b0;
            // NOTE: default, strobe is one clk wide

        if (i_cpu_wr_sync == 1'b0) begin
            // idle, hold the frame in reset so every burst
            // starts aligned on beat 0
            i_beat       <= 2'b00;
            i_frame_done <= 1'b0;
        end else if ((i_cpu_clk_rise == 1'b1) && (i_frame_done == 1'b0)) begin
            // the host holds each beat for the whole cpu_clk period,
            // so the wires are quiet when we sample them here
            if (i_beat[1] == 1'b1) begin
                m_wrdata[i_beat[0]*16 +: 16] <= cpu_data_async;
            end else begin
                m_addr[i_beat[0]*16 +: 16]   <= cpu_data_async;
            end

            if (i_beat == 2'b11) begin
                i_frame_done <= 1'b1;
                    // NOTE: ignore any extra cpu_clk in this frame
                m_wvalid     <= 1'b1;
            end else begin
                i_beat <= i_beat + 2'd1;
            end
        end

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            m_addr       <= 32'h0000_0000;
            m_wrdata     <= 32'h0000_0000;
            m_wvalid     <= 1'b0;
            i_beat       <= 2'b00;
            i_frame_done <= 1'b0;
        end
    end

endmodule
