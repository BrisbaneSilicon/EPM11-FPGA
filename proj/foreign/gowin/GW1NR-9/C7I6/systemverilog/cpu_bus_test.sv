`timescale 1ns/1ps

module cpu_bus_test
#(
    parameter int WATCH_COUNT   = 4,
    parameter int PROBE_BUS_W   = 128,
    parameter int PROBE_WATCH_W = 128,
    parameter int SYNC_STAGES   = 2
)
(
    // -------------- clocking --------------

    input   logic                           clk,
    input   logic                           srst,


    // -------------- fabric slave --------------
    // NOTE: named from OUR point of view, so
    // s_wrdata is what the master writes into
    // us and s_rddata is what we hand back...

    input   logic   [31:0]                  s_addr,
    input   logic   [31:0]                  s_wrdata,
    input   logic   [3:0]                   s_wstrb,
    output  logic   [31:0]                  s_rddata,
    input   logic                           s_valid,
    output  logic                           s_ready,


    // -------------- bus debug --------------

    input   logic   [15:0]                  dbg_data,
    input   logic   [1:0]                   dbg_beat,
        // NOTE: observation taps from busV2,
        // for the probe only - nothing here
        // drives logic...


    // -------------- host bus --------------

    input   logic                           cpu_clk_async,
    input   logic                           cpu_wr_async,
        // NOTE: taken straight off the pads so
        // the probe shows the lines themselves,
        // not our interpretation of them...

    input   logic                           watch_clear_async,
        // NOTE: from the EIO, lets the host
        // re-zero the words over JTAG without
        // a power cycle...


    // -------------- probes --------------

    output  logic   [PROBE_WATCH_W-1:0]     probe_watch,
    output  logic   [PROBE_BUS_W-1:0]       probe_bus
        // NOTE: bus layout:
        //
        //      word 0  [0]         pclk        cpu_clk, synchronised
        //              [1]         io          cpu_wr,  synchronised
        //              [3:2]       beat        burst position 0..3
        //              [4]         wvalid      write complete, one clk wide
        //              [15:5]      reserved    keeps the words below aligned
        //              [31:16]     data_bus    the 16 wires, as busV2 sampled them
        //      word 1  [63:32]     addr        address being accessed
        //      word 2  [95:64]     wdata       value the host is writing
        //      word 3  [127:96]    rdata       value we are handing back on a read
);

    localparam [(32*WATCH_COUNT)-1:0] cWATCH_ADDR = {
        32'hFFFF_FFFC,      // [3]
        32'h5A5A_A5A4,      // [2]
        32'h0000_00FC,      // [1]
        32'h0000_0000       // [0]
    };

    localparam [31:0] cMISS_MARKER = 32'hDEAD_BEEF;


    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    logic   [WATCH_COUNT-1:0] [31:0]   i_watch_data;
    logic   [WATCH_COUNT-1:0]          i_watch_hit;

    logic                               i_cpu_clk_sync;
    logic                               i_cpu_wr_sync;
    logic                               i_watch_clear;

    integer                             i_wi;
    integer                             i_ri;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------


    // NOTE: Address
    // decode
    // ------------

    genvar w;
    generate
        for (w = 0; w < WATCH_COUNT; w = w + 1) begin : gen_watch_hit
            assign i_watch_hit[w] = (s_addr == cWATCH_ADDR[32*w +: 32]);
        end
    endgenerate


    // NOTE: Watched
    // memory words
    // ------------

    // NOTE: the EIO drives watch_clear from the
    // JTAG register domain. On this part that is
    // the system clock already, but synchronise
    // anyway so the module stays correct if the
    // ELA is ever given its own clock...

    dff_synchroniser #(
        .SYNC_STAGES   (SYNC_STAGES)
    ) dff_synchroniser_clear_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (i_watch_clear),

        .async          (watch_clear_async)
    );

    always @(posedge clk) begin
        // defaults
        s_ready <= 1'b0;

        if (i_watch_clear == 1'b1) begin
            for (i_wi = 0; i_wi < WATCH_COUNT; i_wi = i_wi + 1) begin
                i_watch_data[i_wi] <= 32'h0000_0000;
            end
        end else if (s_valid == 1'b1) begin
            s_ready <= 1'b1;

            for (i_wi = 0; i_wi < WATCH_COUNT; i_wi = i_wi + 1) begin
                if (i_watch_hit[i_wi] == 1'b1) begin
                    i_watch_data[i_wi] <= s_wrdata;
                end
            end
        end

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            for (i_wi = 0; i_wi < WATCH_COUNT; i_wi = i_wi + 1) begin
                i_watch_data[i_wi] <= 32'h0000_0000;
            end

            s_ready <= 1'b0;
        end
    end


    // NOTE: Read
    // back
    // ------------

    // NOTE: so the host can verify what it
    // stored. busV2 raises m_ren at beat 1 and
    // does not sample us until the beat 2
    // falling edge, so one clk of lookup
    // latency is plenty...

    always @(posedge clk) begin

        if (s_wstrb == 4'h0) begin
            s_rddata <= cMISS_MARKER;
                // NOTE: reads of an unwatched
                // address are then obvious...

            for (i_ri = 0; i_ri < WATCH_COUNT; i_ri = i_ri + 1) begin
                if (i_watch_hit[i_ri] == 1'b1) begin
                    s_rddata <= i_watch_data[i_ri];
                end
            end
        end

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            s_rddata <= 32'h0000_0000;
        end
    end


    // NOTE: Probe
    // assembly
    // ------------

    // NOTE: cpu_clk and cpu_wr are asynchronous,
    // so they get their own synchronisers before
    // the ELA samples them. Same depth busV2
    // uses, so what the probe shows is what
    // busV2 actually acted on...

    dff_synchroniser #(
        .SYNC_STAGES   (SYNC_STAGES)
    ) dff_synchroniser_cpu_clk_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (i_cpu_clk_sync),

        .async          (cpu_clk_async)
    );

    dff_synchroniser #(
        .SYNC_STAGES   (SYNC_STAGES)
    ) dff_synchroniser_cpu_wr_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (i_cpu_wr_sync),

        .async          (cpu_wr_async)
    );

    assign probe_bus = {
        s_rddata,           // [127:96] word 3, handed back on a read
        s_wrdata,           // [95:64]  word 2, value being written
        s_addr,             // [63:32]  word 1, address being accessed
        dbg_data,           // [31:16]  word 0, the 16 wires as sampled
        11'h000,            // [15:5]   reserved, keeps the words aligned
        s_valid,            // [4]      transaction requires downstream data
        dbg_beat,           // [3:2]    burst position
        i_cpu_wr_sync,      // [1]      cpu_wr
        i_cpu_clk_sync      // [0]      cpu_clk
    };

    assign probe_watch = {
        i_watch_data[3],    // [127:96]
        i_watch_data[2],    // [95:64]
        i_watch_data[1],    // [63:32]
        i_watch_data[0]     // [31:0]
    };

endmodule
