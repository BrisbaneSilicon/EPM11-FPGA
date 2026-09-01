// -------------------------------------------------------------------------
// DESCRIPTION :
//
// Testbench for busV2 and cpu_watch together, wired exactly as top.sv
// wires them.
//
// -------------------------------------------------------------------------
// SPECIFICATION :
//
// Proves the watched words start at zero, take a host write only at their
// own full 32-bit address, read back, and land in the probe bundles where
// the ELA expects to find them.
//
// The address decode is checked from both directions: a write with the
// right low half but the wrong upper half must miss, and vice versa. That
// is what proves BOTH address beats are being captured.
//
// Run with  ./run.sh watch
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps
module tb_cpu_watch;

    parameter int pSYNC_STAGES = 2;

    parameter PCLK_LO = 250;
    parameter PCLK_HI = 250;
    parameter GAP     = 3000;

    localparam real CLK_HALF = 9.8039;      // 51 MHz

    localparam [31:0] A0 = 32'h0000_0000;
    localparam [31:0] A1 = 32'h0000_00FC;
    localparam [31:0] A2 = 32'h5A5A_A5A4;
    localparam [31:0] A3 = 32'hFFFF_FFFC;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // ---- host driven pads ----
    reg         h_io    = 1'b0;
    reg         h_pclk  = 1'b0;
    reg  [15:0] h_data  = 16'h0000;
    reg         h_drive = 1'b0;

    wire [15:0] cpu_data;
    assign cpu_data = h_drive ? h_data : 16'hzzzz;

    pulldown pd [15:0] (cpu_data);      // as per the .cst

    // ---- fabric side, names as in top.sv ----
    wire [31:0] i_bus_addr;
    wire [31:0] i_bus_wdata;
    wire [31:0] i_bus_rdata;
    wire        i_bus_wvalid;
    wire        i_bus_ren;

    wire [127:0] probe_bus;
    wire [15:0]  i_dbg_data;
    wire [1:0]   i_dbg_beat;
    reg          watch_clear = 1'b0;
    wire [127:0] probe_watch;

    busV2 #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) busV2_inst (
        .clk            (clk),
        .srst           (~rst_n),

        .cpu_data_async (cpu_data),
        .cpu_clk_async  (h_pclk),
        .cpu_wr_async   (h_io),

        .m_addr         (i_bus_addr),
        .m_wrdata       (i_bus_wdata),
        .m_wvalid       (i_bus_wvalid),
        .m_ren          (i_bus_ren),
        .m_rddata       (i_bus_rdata),

        .dbg_data       (i_dbg_data),
        .dbg_beat       (i_dbg_beat),
        .dbg_is_read    (),
        .dbg_drive      ()
    );

    cpu_watch #(
        .pWATCH_COUNT       (4),
        .pPROBE_BUS_W       (128),
        .pPROBE_WATCH_W     (128),
        .pSYNC_STAGES       (pSYNC_STAGES)
    ) cpu_watch_inst (
        .clk                (clk),
        .srst               (~rst_n),

        .s_addr             (i_bus_addr),
        .s_wrdata           (i_bus_wdata),
        .s_wvalid           (i_bus_wvalid),
        .s_ren              (i_bus_ren),
        .s_rddata           (i_bus_rdata),

        .dbg_data           (i_dbg_data),
        .dbg_beat           (i_dbg_beat),

        .cpu_clk_async      (h_pclk),
        .cpu_wr_async       (h_io),
        .watch_clear_async  (watch_clear),

        .probe_bus          (probe_bus),
        .probe_watch        (probe_watch)
    );

    // ---- probe field accessors, mirroring the documented layout ----
    wire        pb_pclk     = probe_bus[0];
    wire        pb_io       = probe_bus[1];
    wire [1:0]  pb_beat     = probe_bus[3:2];
    wire        pb_wvalid   = probe_bus[4];
    wire [10:0] pb_rsvd     = probe_bus[15:5];
    wire [15:0] pb_data_bus = probe_bus[31:16];
    wire [31:0] pb_addr     = probe_bus[63:32];
    wire [31:0] pb_wdata    = probe_bus[95:64];
    wire [31:0] pb_rdata    = probe_bus[127:96];

    wire [31:0] pw0 = probe_watch[31:0];
    wire [31:0] pw1 = probe_watch[63:32];
    wire [31:0] pw2 = probe_watch[95:64];
    wire [31:0] pw3 = probe_watch[127:96];

    integer errors = 0;

    // ---- contention monitor ----
    integer contention = 0;
    always @(*) begin
        if (h_drive === 1'b1 && busV2_inst.i_bus_drive === 1'b1) begin
            $display("CONTENTION at %0t", $time);
            contention = contention + 1;
        end
    end

    // ---------------- host model ----------------

    task host_beat(input [15:0] value);
        begin
            h_data = value; h_drive = 1'b1;
            #(PCLK_LO); h_pclk = 1'b1; #(PCLK_HI); h_pclk = 1'b0;
        end
    endtask

    task host_write(input [31:0] addr, input [31:0] data);
        begin
            h_drive = 1'b1; h_data = addr[15:0];
            #100; h_io = 1'b1; #100;
            host_beat(addr[15:0]);
            host_beat(addr[31:16]);
            host_beat(data[15:0]);
            host_beat(data[31:16]);
            #200; h_io = 1'b0; h_drive = 1'b0;
            #(GAP);
        end
    endtask

    task host_read(input [31:0] addr, output [31:0] data);
        begin
            h_io = 1'b0;
            h_drive = 1'b1; h_data = addr[15:0];
            #200;
            host_beat(addr[15:0]);
            host_beat(addr[31:16]);
            h_drive = 1'b0;

            #(PCLK_LO); h_pclk = 1'b1;
            #(PCLK_HI/2); data[15:0] = cpu_data;
            #(PCLK_HI/2); h_pclk = 1'b0;

            #(PCLK_LO); h_pclk = 1'b1;
            #(PCLK_HI/2); data[31:16] = cpu_data;
            #(PCLK_HI/2); h_pclk = 1'b0;

            #(GAP);
        end
    endtask

    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got %08h exp %08h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: %08h", name, got);
            end
        end
    endtask

    task chk_watch(input [255:0] name,
                   input [31:0] e0, input [31:0] e1,
                   input [31:0] e2, input [31:0] e3);
        begin
            chk({name, " w0"}, pw0, e0);
            chk({name, " w1"}, pw1, e1);
            chk({name, " w2"}, pw2, e2);
            chk({name, " w3"}, pw3, e3);
        end
    endtask

    reg [31:0] rd;

    initial begin
        $dumpfile("output/tb_cpu_watch.vcd");
        $dumpvars(0, tb_cpu_watch);

        #200 rst_n = 1'b1;
        #(GAP);

        // ---- all four start at zero ----
        chk_watch("reset", 32'h0, 32'h0, 32'h0, 32'h0);

        // ---- each address takes its own write, and only its own ----
        host_write(A0, 32'hFFFF_FFFF);      // all data bits high
        chk_watch("after A0", 32'hFFFF_FFFF, 32'h0, 32'h0, 32'h0);
        chk("A0 probe addr",  pb_addr,  A0);
        chk("A0 probe wdata", pb_wdata, 32'hFFFF_FFFF);

        host_write(A1, 32'hAAAA_AAAA);      // alternating
        chk_watch("after A1", 32'hFFFF_FFFF, 32'hAAAA_AAAA, 32'h0, 32'h0);

        host_write(A2, 32'h5555_5555);      // the other alternating
        chk_watch("after A2", 32'hFFFF_FFFF, 32'hAAAA_AAAA, 32'h5555_5555, 32'h0);

        host_write(A3, 32'h0123_4567);      // walking nibbles
        chk_watch("after A3", 32'hFFFF_FFFF, 32'hAAAA_AAAA, 32'h5555_5555, 32'h0123_4567);

        // ---- an unwatched address must disturb nothing ----
        host_write(32'h1234_5678, 32'hDEAD_0000);
        chk_watch("after miss", 32'hFFFF_FFFF, 32'hAAAA_AAAA, 32'h5555_5555, 32'h0123_4567);

        // ---- the upper address half really is decoded ----
        // A1 is 0000_00FC. Same low half, different upper half, must miss.
        host_write(32'hBEEF_00FC, 32'h0000_0001);
        chk_watch("upper half decoded", 32'hFFFF_FFFF, 32'hAAAA_AAAA, 32'h5555_5555, 32'h0123_4567);

        // ---- the lower address half really is decoded ----
        // A3 is FFFF_FFFC. Same upper half, different low half, must miss.
        host_write(32'hFFFF_0000, 32'h0000_0002);
        chk_watch("lower half decoded", 32'hFFFF_FFFF, 32'hAAAA_AAAA, 32'h5555_5555, 32'h0123_4567);

        // ---- read back every word ----
        host_read(A0, rd); chk("read A0", rd, 32'hFFFF_FFFF);
        host_read(A1, rd); chk("read A1", rd, 32'hAAAA_AAAA);
        host_read(A2, rd); chk("read A2", rd, 32'h5555_5555);
        host_read(A3, rd); chk("read A3", rd, 32'h0123_4567);

        // ---- an unwatched read is flagged ----
        host_read(32'h1111_2222, rd);
        chk("read miss", rd, 32'hDEAD_BEEF);

        // ---- overwrite works, walking one over the data word ----
        host_write(A2, 32'h8000_0001);
        chk_watch("overwrite A2", 32'hFFFF_FFFF, 32'hAAAA_AAAA, 32'h8000_0001, 32'h0123_4567);

        // ---- the probe carries what the ELA is supposed to see ----
        chk("probe beat at idle",  {30'b0, pb_beat}, 32'h0);
        chk("reserved bits zero",  {21'b0, pb_rsvd}, 32'h0);
        chk("wvalid low at idle",  {31'b0, pb_wvalid}, 32'h0);

        // rdata still holds the previous read, which was the unwatched
        // one, so the miss marker is visible on the probe.
        chk("probe rdata holds miss marker", pb_rdata, 32'hDEAD_BEEF);

        // Read a known word and confirm the probe reports what we served.
        host_read(A2, rd);
        chk("read A2 after overwrite",  rd,       32'h8000_0001);
        chk("probe rdata tracks a read", pb_rdata, 32'h8000_0001);
        chk("probe addr tracks a read",  pb_addr,  A2);


        // ---- EIO clear re-zeroes every word ----
        watch_clear = 1'b1;
        #500;
        watch_clear = 1'b0;
        #500;
        chk_watch("after eio clear", 32'h0, 32'h0, 32'h0, 32'h0);

        // ---- and writes still land afterwards ----
        host_write(A1, 32'h1357_9BDF);
        chk_watch("write after clear", 32'h0, 32'h1357_9BDF, 32'h0, 32'h0);

        if (contention != 0) begin
            $display("FAIL contention events: %0d", contention);
            errors = errors + 1;
        end else begin
            $display("PASS no bus contention");
        end

        if (errors == 0) $display("*** ALL TESTS PASSED ***");
        else             $display("*** %0d FAILURE(S) ***", errors);
        $finish;
    end

endmodule
