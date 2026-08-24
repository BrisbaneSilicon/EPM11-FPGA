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
// DESCRIPTION : Double data rate host bus slave. A beat lands on every
//               cpu_clk edge instead of every rising edge, so a burst
//               costs half the cpu_clk cycles busV2 needs.
//
// -------------------------------------------------------------------------
// SPECIFICATION :
//
// cpu_wr = 1, write, 2 cpu_clk cycles, all 4 beats from the host:
//   edge 0, rise : addr [15:0]
//   edge 1, fall : addr [31:16]
//   edge 2, rise : data [15:0]
//   edge 3, fall : data [31:16]
//
// cpu_wr = 0, read, 3 cpu_clk cycles:
//   edge 0, rise : addr [15:0]        host drives
//   edge 1, fall : addr [31:16]       host drives, then lets go
//   edge 2, rise : turnaround
//   edge 3, fall : we take the bus and present data [15:0]
//   edge 4, rise : host samples data [15:0],  we present data [31:16]
//   edge 5, fall : host samples data [31:16], we let go
//
// The read costs a whole cpu_clk cycle of turnaround because there is no
// longer a quiet half cycle to hand the wires over in. That window is also
// what the fabric gets to answer m_ren, so it is a full cpu_clk period
// rather than the half period busV2 allowed.
//
// cpu_clk is fully asynchronous and the host may take as long as it likes
// between edges, including in the middle of a burst. A burst is a fixed
// number of edges, so its end is what frames it: phase wraps to 0 on the
// last beat and the next edge is beat 0 of whatever comes next. Nothing is
// timed, so there is no gap to leave and no stall that can desync us.
//
// Both bursts are an even number of edges, so beat 0 always lands on a
// rising edge. Phase 0 only accepts a rising edge, which keeps that
// invariant true and lets a cpu_wr edge pull us back into step.
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module busV3_ddr
#(
    parameter int pSYNC_STAGES = 2
)
(
    // ---------------- clocking ----------------

    input   logic           clk,
    input   logic           srst,

    // ---------------- host bus, asynchronous ----------------

    inout   wire    [15:0]  cpu_data_async,
    input   logic           cpu_clk_async,
    input   logic           cpu_wr_async,

    // ---------------- fabric master ----------------

    output  logic   [31:0]  m_addr,
    output  logic   [31:0]  m_wrdata,
    output  logic           m_wvalid,
        // NOTE: one clk strobe, write burst complete
    output  logic           m_ren,
        // NOTE: one clk strobe, read address is ready
    input   logic   [31:0]  m_rddata
);

    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    logic           i_cpu_clk_rise;
    logic           i_cpu_clk_fall;
    logic           i_cpu_clk_edge;

    logic           i_cpu_wr_sync;
    logic           i_cpu_wr_edge;

    logic   [15:0]  i_data_ff1;
    logic   [15:0]  i_data;

    logic   [2:0]   i_phase;
    logic           i_is_read;

    logic   [15:0]  i_bus_out;
    logic           i_bus_drive;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    sync_edge #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) sync_edge_cpu_clk_inst (
        .clk            (clk),
        .srst           (srst),

        .sync           (),
        .rise           (i_cpu_clk_rise),
        .fall           (i_cpu_clk_fall),
        .edge_any       (),

        .async          (cpu_clk_async)
    );

    sync_edge #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) sync_edge_cpu_wr_inst (
        .clk            (clk),
        .srst           (srst),

        .sync           (i_cpu_wr_sync),
        .rise           (),
        .fall           (),
        .edge_any       (i_cpu_wr_edge),

        .async          (cpu_wr_async)
    );

    assign i_cpu_clk_edge = i_cpu_clk_rise | i_cpu_clk_fall;

    // At DDR the host changes the wires halfway between edges, and our edge
    // ticks arrive pSYNC_STAGES clks late, so reading the pads directly
    // would race the next beat. Delay the data by the same stages and the
    // sample lands back where the edge was.

    always @(posedge clk) begin

        i_data_ff1  <= cpu_data_async;
        i_data      <= i_data_ff1;

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            i_data_ff1  <= 16'h0000;
            i_data      <= 16'h0000;
        end
    end

    assign cpu_data_async = i_bus_drive ? i_bus_out : 16'hzzzz;

    // Every cpu_clk edge is a beat, not just the rising ones

    always @(posedge clk) begin

        m_wvalid <= 1'b0;
            // NOTE: default, strobes are one clk wide
        m_ren    <= 1'b0;

        if ((i_cpu_wr_edge == 1'b1) && (i_cpu_clk_edge == 1'b0)) begin
            // cpu_wr only moves between bursts, so it is a free resync
            i_phase     <= 3'd0;
            i_bus_drive <= 1'b0;
        end else if (i_cpu_clk_edge == 1'b1) begin
            case (i_phase)
                3'd0: begin
                    if (i_cpu_clk_rise == 1'b1) begin
                        // NOTE: bursts open on a rise
                        i_is_read       <= ~i_cpu_wr_sync;
                        m_addr[15:0]    <= i_data;
                        i_phase         <= 3'd1;
                    end
                end

                3'd1: begin
                    m_addr[31:16]   <= i_data;
                    m_ren           <= i_is_read;
                        // NOTE: address done, fetch it
                    i_phase         <= 3'd2;
                end

                3'd2: begin
                    if (i_is_read == 1'b0) begin
                        // NOTE: a read spends this edge on turnaround
                        m_wrdata[15:0] <= i_data;
                    end
                    i_phase         <= 3'd3;
                end

                3'd3: begin
                    if (i_is_read == 1'b1) begin
                        i_bus_out   <= m_rddata[15:0];
                        i_bus_drive <= 1'b1;
                            // NOTE: our turn on the wires
                        i_phase     <= 3'd4;
                    end else begin
                        m_wrdata[31:16] <= i_data;
                        m_wvalid        <= 1'b1;
                        i_phase         <= 3'd0;
                            // NOTE: write done, ready again
                    end
                end

                3'd4: begin
                    i_bus_out       <= m_rddata[31:16];
                    i_phase         <= 3'd5;
                end

                3'd5: begin
                    i_bus_drive     <= 1'b0;
                        // NOTE: let go
                    i_phase         <= 3'd0;
                        // NOTE: read done, ready again
                end

                default: begin
                    i_phase         <= 3'd0;
                    i_bus_drive     <= 1'b0;
                end
            endcase
        end

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            m_addr      <= 32'h0000_0000;
            m_wrdata    <= 32'h0000_0000;
            m_wvalid    <= 1'b0;
            m_ren       <= 1'b0;
            i_phase     <= 3'd0;
            i_is_read   <= 1'b0;
            i_bus_out   <= 16'h0000;
            i_bus_drive <= 1'b0;
        end
    end

endmodule
