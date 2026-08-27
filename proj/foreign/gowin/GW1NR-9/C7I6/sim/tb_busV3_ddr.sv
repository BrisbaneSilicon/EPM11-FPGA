// -------------------------------------------------------------------------
// DESCRIPTION :
//
// Testbench for busV3_ddr, the double data rate host bus slave.
//
// -------------------------------------------------------------------------
// SPECIFICATION :
//
// As tb_busV2, but a beat lands on every cpu_clk edge rather than every
// rising edge, and a read costs a whole cpu_clk cycle of turnaround.
//
// Run with  ./run.sh busV3
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_busV3_ddr;

    parameter HALF         = 250;       // pclk half period, one beat per edge
    parameter GAP          = 3000;      // nothing depends on this any more

    localparam real CLK_HALF = 9.8039;  // 51 MHz

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // host driven pads
    reg         h_io    = 1'b0;
    reg         h_pclk  = 1'b0;
    reg  [15:0] h_data  = 16'h0000;
    reg         h_drive = 1'b0;

    wire [15:0] cpu_data;
    assign cpu_data = h_drive ? h_data : 16'hzzzz;

    pulldown pd [15:0] (cpu_data);      // as per the .cst

    wire [31:0] cpu_addr;
    wire [31:0] cpu_rdata;
    wire        cpu_valid;
    wire        cpu_ren;
    reg  [31:0] cpu_wdata = 32'h0;

    busV3_ddr dut (
        .clk            (clk),
        .srst           (~rst_n),

        .cpu_data_async (cpu_data),
        .cpu_clk_async  (h_pclk),
        .cpu_wr_async   (h_io),

        .m_addr         (cpu_addr),
        .m_wrdata       (cpu_rdata),
        .m_wvalid       (cpu_valid),
        .m_ren          (cpu_ren),
        .m_rddata       (cpu_wdata)
    );

    // ---- fabric memory model, one clk of lookup latency ----
    function [31:0] mem_lookup(input [31:0] a);
        mem_lookup = {a[15:0] ^ 16'hA5A5, a[15:0] + 16'h1234};
    endfunction

    always @(posedge clk) begin
        if (cpu_ren) cpu_wdata <= mem_lookup(cpu_addr);
    end

    // ---- contention monitor ----
    integer contention = 0;
    always @(*) begin
        if (h_drive === 1'b1 && dut.i_bus_drive === 1'b1) begin
            $display("CONTENTION at %0t: host and FPGA both driving", $time);
            contention = contention + 1;
        end
    end

    integer errors = 0, valid_count = 0, ren_count = 0;
    reg [31:0] seen_addr, seen_data;

    always @(posedge clk) begin
        if (cpu_valid) begin
            seen_addr   <= cpu_addr;
            seen_data   <= cpu_rdata;
            valid_count <= valid_count + 1;
        end
        if (cpu_ren) ren_count <= ren_count + 1;
    end

    // ---------------- DDR host model ----------------
    //
    // Data changes midway between edges, so every beat gets HALF/2 of setup
    // and HALF/2 of hold around the edge that captures it.

    task ddr_beat(input [15:0] v);      // present a beat, then clock it in
        begin
            h_data = v; h_drive = 1'b1;
            #(HALF/2);
            h_pclk = ~h_pclk;
            #(HALF/2);
        end
    endtask

    task ddr_turn;                      // toggle pclk, drive nothing
        begin
            #(HALF/2);
            h_pclk = ~h_pclk;
            #(HALF/2);
        end
    endtask

    task ddr_sample(output [15:0] v);   // toggle pclk, read what the FPGA drives
        begin
            #(HALF/2);
            h_pclk = ~h_pclk;
            #10;
            v = cpu_data;
            #(HALF/2 - 10);
        end
    endtask

    task host_write(input [31:0] addr, input [31:0] data);
        begin
            h_drive = 1'b1; h_data = addr[15:0];
            #100; h_io = 1'b1; #100;
            ddr_beat(addr[15:0]);       // edge 0, rise
            ddr_beat(addr[31:16]);      // edge 1, fall
            ddr_beat(data[15:0]);       // edge 2, rise
            ddr_beat(data[31:16]);      // edge 3, fall
            #200; h_io = 1'b0; h_drive = 1'b0;
            #(GAP);
        end
    endtask

    task host_read(input [31:0] addr, output [31:0] data);
        begin
            h_io = 1'b0;                // read direction
            h_drive = 1'b1; h_data = addr[15:0];
            #200;
            ddr_beat(addr[15:0]);       // edge 0, rise
            ddr_beat(addr[31:16]);      // edge 1, fall
            h_drive = 1'b0;             // let go, the FPGA drives next
            ddr_turn;                   // edge 2, rise
            ddr_turn;                   // edge 3, fall
            ddr_sample(data[15:0]);     // edge 4, rise
            ddr_sample(data[31:16]);    // edge 5, fall
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

    task chk_int(input [255:0] name, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got %0d exp %0d", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: %0d", name, got);
            end
        end
    endtask

    reg [31:0] rd;

    initial begin
        $dumpfile("output/tb_busV3_ddr.vcd");
        $dumpvars(0, tb_busV3_ddr);

        #200 rst_n = 1'b1;
        #(GAP);

        // ---- write, 2 pclk cycles ----
        host_write(32'h1234_5678, 32'hCAFE_F00D);
        chk("write addr", seen_addr, 32'h1234_5678);
        chk("write data", seen_data, 32'hCAFE_F00D);
        chk_int("write valid count", valid_count, 1);
        chk_int("no ren on write", ren_count, 0);

        // ---- read after write, io edge resync ----
        host_read(32'h0000_0010, rd);
        chk("read addr seen", cpu_addr, 32'h0000_0010);
        chk("read data", rd, mem_lookup(32'h0000_0010));
        chk_int("ren count", ren_count, 1);
        chk_int("no valid on read", valid_count, 1);

        // ---- back to back reads, framed only by the idle timeout ----
        host_read(32'h0000_0020, rd);
        chk("read2 data", rd, mem_lookup(32'h0000_0020));
        host_read(32'hABCD_1234, rd);
        chk("read3 data", rd, mem_lookup(32'hABCD_1234));
        chk("read3 addr", cpu_addr, 32'hABCD_1234);

        // ---- write after read ----
        host_write(32'h8765_4321, 32'h0BAD_C0DE);
        chk("write2 addr", seen_addr, 32'h8765_4321);
        chk("write2 data", seen_data, 32'h0BAD_C0DE);
        chk_int("valid count", valid_count, 2);

        // ---- all ones, and a read must not disturb stored write data ----
        host_write(32'hFFFF_FFFF, 32'hFFFF_FFFF);
        chk("all ones addr", seen_addr, 32'hFFFF_FFFF);
        chk("all ones data", seen_data, 32'hFFFF_FFFF);
        host_read(32'h0000_0040, rd);
        chk("read4 data", rd, mem_lookup(32'h0000_0040));
        chk("wdata untouched by read", cpu_rdata, 32'hFFFF_FFFF);

        // ---- the RPI stalls in the middle of a burst ----
        // Nothing is timed any more, so a burst must survive the host being
        // descheduled between beats.
        h_drive = 1'b1; h_data = 32'h1111_2222 & 16'hFFFF;
        #100; h_io = 1'b1; #100;
        ddr_beat(16'h2222);         // edge 0, addr lo
        #50000;                     // 50 us of nothing, mid burst
        ddr_beat(16'h1111);         // edge 1, addr hi
        #17000;                     // and again
        ddr_beat(16'h4444);         // edge 2, data lo
        #123000;                    // and again, much longer
        ddr_beat(16'h3333);         // edge 3, data hi
        #200; h_io = 1'b0; h_drive = 1'b0;
        #(GAP);
        chk("stalled write addr", seen_addr, 32'h1111_2222);
        chk("stalled write data", seen_data, 32'h3333_4444);
        chk_int("stalled write valid count", valid_count, 4);

        // ---- back to back writes with no gap at all ----
        // The burst frames itself, so the next edge after the last beat is
        // beat 0 of the next burst.
        h_io = 1'b1; h_drive = 1'b1;
        #200;
        ddr_beat(16'hAAAA); ddr_beat(16'hBBBB);
        ddr_beat(16'hCCCC); ddr_beat(16'hDDDD);     // burst 1 ends
        ddr_beat(16'h0001); ddr_beat(16'h0002);
        ddr_beat(16'h0003); ddr_beat(16'h0004);     // burst 2, zero gap
        #200; h_io = 1'b0; h_drive = 1'b0;
        #(GAP);
        chk("gapless burst 1+2 addr", seen_addr, 32'h0002_0001);
        chk("gapless burst 1+2 data", seen_data, 32'h0004_0003);
        chk_int("gapless valid count", valid_count, 6);

        // ---- FPGA must be off the bus at idle ----
        #(GAP);
        if (cpu_data !== 16'h0000) begin
            $display("FAIL idle: bus is %04h, expected pulldowns to win", cpu_data);
            errors = errors + 1;
        end else begin
            $display("PASS idle: FPGA released the bus");
        end

        chk_int("contention events", contention, 0);

        if (errors == 0) $display("\n*** ALL TESTS PASSED ***");
        else             $display("\n*** %0d FAILURE(S) ***", errors);
        $finish;
    end

endmodule
