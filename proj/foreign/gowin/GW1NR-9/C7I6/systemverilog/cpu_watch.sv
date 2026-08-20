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
// DESCRIPTION :
//
// Four probe-visible memory words sitting behind the host bus, plus the
// probe bundles the fpgacapZero cores sample. Split out of top.sv so it
// can be simulated against the real busV2 rather than against a copy.
//
// -------------------------------------------------------------------------
// SPECIFICATION :
//
// Words are decoded on the FULL 32-bit address. A truncated decode would
// ignore the upper half and so hide a broken beat 1 - the exact match is
// what proves BOTH address beats landed.
//
// probe_bus goes to the ELA (fcapz_ela_gowin probe_in, SAMPLE_W=104) and
// is byte aligned so a raw hex sample decodes by eye:
//
//   byte  0..3    [31:0]      bus_addr        address being accessed
//   byte  4..7    [63:32]     bus_wdata       value to be stored
//   byte  8..9    [79:64]     bus_data_in     raw beat, as busV2 sampled it
//   byte 10       [80]        pclk            Pclk, synchronised
//                 [81]        io              IO,   synchronised
//                 [83:82]     beat            burst position 0..3
//                 [84]        is_read         direction latched at beat 0
//                 [85]        bus_drive       FPGA is driving cpu[15:0]
//                 [86]        bus_wvalid      write burst complete, 1 clk
//                 [87]        bus_ren         read address ready, 1 clk
//   byte 11       [91:88]     watch_we        watch word actually written
//                 [95:92]     watch_hit       address decode, combinational
//   byte 12       [96]        watch_miss      completed write matched nothing
//                 [97]        qualifier       storage qualification bit
//                 [103:98]    reserved
//
// probe_watch goes to the EIO (eio_probe_in) rather than the ELA. The four
// words are slow state, not waveform - storing them 64 deep would burn
// BSRAM to hold the same value 64 times. EIO reads them on demand for
// free.
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module cpu_watch #(
    parameter int WATCH_COUNT   = 4,
    parameter int PROBE_BUS_W   = 104,
    parameter int PROBE_WATCH_W = 128
) (
    input                               clk,
    input                               rst_n,


    // -------------- host bus --------------
    // NOTE: named from the fabric side, so
    // wdata is what the host writes to us.

    input       [31:0]                  bus_addr,
    input       [31:0]                  bus_wdata,
    input                               bus_wvalid,
    input                               bus_ren,
    output  reg [31:0]                  bus_rdata,

    input       [19:0]                  bus_dbg,
        // NOTE: busV2 internals, see its
        // dbg port for the layout.


    // -------------- raw pads --------------

    input                               pclk_async,
    input                               io_async,


    // -------------- host control --------------

    input                               watch_clear,
        // NOTE: from the EIO, lets the host
        // re-zero the words over JTAG without
        // a power cycle.


    // -------------- probes --------------

    output      [PROBE_BUS_W-1:0]       probe_bus,
    output      [PROBE_WATCH_W-1:0]     probe_watch,
    output                              probe_qualifier
);

    // Picked so every meaningful address bit is seen both low and high,
    // and so the upper halves are not all the same value:
    //      [0] 0000_0000   all bits low
    //      [1] 0000_00FC   low half only, upper half zero
    //      [2] 5A5A_A5A4   alternating, both halves non-zero
    //      [3] FFFF_FFFC   all bits high
    // Bits [1:0] stay low, the words are 4-byte aligned.
    //
    // NOTE: flat, not a packed array of
    // parameters - iverilog rejects those.

    localparam [(32*WATCH_COUNT)-1:0] WATCH_ADDR = {
        32'hFFFF_FFFC,      // [3]
        32'h5A5A_A5A4,      // [2]
        32'h0000_00FC,      // [1]
        32'h0000_0000       // [0]
    };


    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    reg     [WATCH_COUNT-1:0] [31:0]    i_watch_data;
    wire    [WATCH_COUNT-1:0]           i_watch_hit;
    reg     [WATCH_COUNT-1:0]           i_watch_we;
    wire                                i_watch_miss;

    wire                                i_pclk_sync;
    wire                                i_io_sync;
    reg                                 i_pclk_d;

    reg                                 i_clear_p1;
    reg                                 i_clear_p0;

    wire    [15:0]                      i_dbg_data_in;
    wire    [1:0]                       i_dbg_beat;
    wire                                i_dbg_is_read;
    wire                                i_dbg_bus_drive;

    wire                                i_qualifier;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    assign i_dbg_data_in   = bus_dbg[15:0];
    assign i_dbg_beat      = bus_dbg[17:16];
    assign i_dbg_is_read   = bus_dbg[18];
    assign i_dbg_bus_drive = bus_dbg[19];

    genvar w;
    generate
        for (w = 0; w < WATCH_COUNT; w = w + 1) begin : gen_watch_hit
            assign i_watch_hit[w] = (bus_addr == WATCH_ADDR[32*w +: 32]);
        end
    endgenerate

    assign i_watch_miss = bus_wvalid & ~(|i_watch_hit);
        // NOTE: a completed write that
        // matched no watched address.

    // The EIO drives watch_clear from the JTAG register domain. On this
    // part that domain is i_sysclk already, but resynchronise anyway so
    // the module stays correct if the ELA is ever given its own clock.

    always @(posedge clk) begin
        if (rst_n == 1'b0) begin
            i_clear_p1 <= 1'b0;
            i_clear_p0 <= 1'b0;
        end else begin
            i_clear_p1 <= watch_clear;
            i_clear_p0 <= i_clear_p1;
        end
    end

    integer wi;
    always @(posedge clk) begin
        if (rst_n == 1'b0) begin
            for (wi = 0; wi < WATCH_COUNT; wi = wi + 1) begin
                i_watch_data[wi] <= 32'h0000_0000;
            end
            i_watch_we <= 0;
        end else begin
            i_watch_we <= 0;
                // NOTE: default, one clk strobe

            if (i_clear_p0 == 1'b1) begin
                for (wi = 0; wi < WATCH_COUNT; wi = wi + 1) begin
                    i_watch_data[wi] <= 32'h0000_0000;
                end
            end else if (bus_wvalid == 1'b1) begin
                for (wi = 0; wi < WATCH_COUNT; wi = wi + 1) begin
                    if (i_watch_hit[wi] == 1'b1) begin
                        i_watch_data[wi] <= bus_wdata;
                        i_watch_we[wi]   <= 1'b1;
                    end
                end
            end
        end
    end

    // NOTE: read back, so the host can verify what it stored. busV2
    // raises cpu_ren at beat 1 and does not sample us until the beat 2
    // falling edge, so one clk of lookup latency is plenty.

    integer ri;
    always @(posedge clk) begin
        if (rst_n == 1'b0) begin
            bus_rdata <= 32'h0000_0000;
        end else if (bus_ren == 1'b1) begin
            bus_rdata <= 32'hDEAD_BEEF;
                // NOTE: reads of an unwatched
                // address are then obvious.

            for (ri = 0; ri < WATCH_COUNT; ri = ri + 1) begin
                if (i_watch_hit[ri] == 1'b1) begin
                    bus_rdata <= i_watch_data[ri];
                end
            end
        end
    end


    // NOTE: probe
    // assembly
    // ------------

    // pclk and io are asynchronous, so they get their own synchronisers
    // before the ELA samples them. Same 2-FF depth busV2 uses internally,
    // so what the probe shows is what busV2 actually acted on.

    bs_dff_sync probe_pclk_sync_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        .async_in   (pclk_async),
        .sync_out   (i_pclk_sync)
    );

    bs_dff_sync probe_io_sync_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        .async_in   (io_async),
        .sync_out   (i_io_sync)
    );

    always @(posedge clk) begin
        if (rst_n == 1'b0) begin
            i_pclk_d <= 1'b0;
        end else begin
            i_pclk_d <= i_pclk_sync;
        end
    end

    // A free-running 51 MHz capture 64 samples deep only spans 1.25 us,
    // which an RPI bit-banging pclk will never fit a burst into. Store a
    // sample per pclk edge instead and 64 samples covers 16 whole bursts,
    // however slowly the host drives them. The bit rides inside the
    // sample because that is what the ELA's storage qualification
    // comparator matches on - it has no separate qualifier input.

    assign i_qualifier = (i_pclk_sync ^ i_pclk_d)
                       | bus_wvalid
                       | bus_ren;

    assign probe_qualifier = i_qualifier;

    assign probe_bus = {
        6'b000000,          // [103:98] reserved
        i_qualifier,        // [97]     storage qualification bit
        i_watch_miss,       // [96]     write matched nothing
        i_watch_hit,        // [95:92]  address decode, combinational
        i_watch_we,         // [91:88]  watch word actually written
        bus_ren,            // [87]     read address ready
        bus_wvalid,         // [86]     write burst complete
        i_dbg_bus_drive,    // [85]     FPGA driving cpu[15:0]
        i_dbg_is_read,      // [84]     direction latched at beat 0
        i_dbg_beat,         // [83:82]  burst position
        i_io_sync,          // [81]     IO
        i_pclk_sync,        // [80]     Pclk
        i_dbg_data_in,      // [79:64]  raw beat as busV2 sampled it
        bus_wdata,          // [63:32]  value to be stored
        bus_addr            // [31:0]   address being accessed
    };

    assign probe_watch = {
        i_watch_data[3],    // [127:96]
        i_watch_data[2],    // [95:64]
        i_watch_data[1],    // [63:32]
        i_watch_data[0]     // [31:0]
    };

endmodule
