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
// probe_bus goes to the ELA. It is four aligned 32-bit words, which is how
// the host reads samples back, so a raw hex capture splits cleanly:
//
//   word 0   [0]         pclk        Pclk, synchronised
//            [1]         io          IO,   synchronised
//            [3:2]       beat        burst position 0..3
//            [4]         wvalid      write burst complete, one clk wide
//            [15:5]      reserved    keeps the words below aligned
//            [31:16]     data_bus    the 16 wires, as busV2 sampled them
//   word 1   [63:32]     addr        address being accessed
//   word 2   [95:64]     wdata       value the host is writing
//   word 3   [127:96]    rdata       value we are handing back on a read
//
// The ordering is not cosmetic. fcapz_ela.v zero-extends the trigger and
// storage-qualification value and mask from 32-bit registers when
// SAMPLE_W > 32 (see its g_sq_wide branch), so ONLY word 0 can be matched
// on. Everything worth triggering or qualifying on - pclk, io, beat,
// wvalid and the raw bus - therefore lives there, and the wide fields sit
// above it.
//
// wvalid is the natural trigger for catching a write:
//
//      --trigger-value 16 --trigger-mask 0x10
//
// (decimal for the value: the fcapz CLI parses --trigger-value with a bare
// int and rejects 0x, unlike every other flag beside it.)
//
// In particular, capture is qualified with CHANGED on pclk:
//
//      --stor-qual-mode 8 --stor-qual-mask 0x01
//
// which stores one sample per pclk edge. A free-running 51 MHz capture 64
// deep spans only 1.25 us, which a host bit-banging pclk will never fit a
// burst into.
//
// probe_watch goes to the EIO rather than the ELA. The four words are slow
// state, not waveform - storing them 64 deep would burn BSRAM holding the
// same value 64 times. EIO reads them on demand for free.
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module cpu_watch #(
    parameter int WATCH_COUNT   = 4,
    parameter int PROBE_BUS_W   = 128,
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
        // NOTE: busV2 internals, see its dbg
        // port. Only the beat counter and the
        // sampled bus are used here; the rest
        // of the bundle is left for whoever
        // needs it next.


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
    output      [PROBE_WATCH_W-1:0]     probe_watch
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

    wire                                i_pclk_sync;
    wire                                i_io_sync;

    reg                                 i_clear_p1;
    reg                                 i_clear_p0;

    wire    [15:0]                      i_dbg_data_bus;
    wire    [1:0]                       i_dbg_beat;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    assign i_dbg_data_bus = bus_dbg[15:0];
    assign i_dbg_beat     = bus_dbg[17:16];

    genvar w;
    generate
        for (w = 0; w < WATCH_COUNT; w = w + 1) begin : gen_watch_hit
            assign i_watch_hit[w] = (bus_addr == WATCH_ADDR[32*w +: 32]);
        end
    endgenerate

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
        end else if (i_clear_p0 == 1'b1) begin
            for (wi = 0; wi < WATCH_COUNT; wi = wi + 1) begin
                i_watch_data[wi] <= 32'h0000_0000;
            end
        end else if (bus_wvalid == 1'b1) begin
            for (wi = 0; wi < WATCH_COUNT; wi = wi + 1) begin
                if (i_watch_hit[wi] == 1'b1) begin
                    i_watch_data[wi] <= bus_wdata;
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

    assign probe_bus = {
        bus_rdata,          // [127:96] word 3, value handed back on a read
        bus_wdata,          // [95:64]  word 2, value being written
        bus_addr,           // [63:32]  word 1, address being accessed
        i_dbg_data_bus,     // [31:16]  word 0, the 16 wires as sampled
        11'h000,            // [15:5]   reserved, keeps the words aligned
        bus_wvalid,         // [4]      write burst complete
        i_dbg_beat,         // [3:2]    burst position
        i_io_sync,          // [1]      IO
        i_pclk_sync         // [0]      Pclk
    };

    assign probe_watch = {
        i_watch_data[3],    // [127:96]
        i_watch_data[2],    // [95:64]
        i_watch_data[1],    // [63:32]
        i_watch_data[0]     // [31:0]
    };

endmodule
