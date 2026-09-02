`timescale 1ns/1ps

module tb_busV2;

    parameter PCLK_LO      = 250;
    parameter PCLK_HI      = 250;
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

    wire [17:0] cpu;
    assign cpu[17]   = h_io;
    assign cpu[16]   = h_pclk;
    assign cpu[15:0] = h_drive ? h_data : 16'hzzzz;

    pulldown pd [17:0] (cpu);       // as per the .cst

    wire [31:0] cpu_addr;
    wire [31:0] cpu_rdata;
    wire        cpu_valid;
    wire        cpu_ren;
    reg  [31:0] cpu_wdata = 32'h0;

    busV2 dut (
        .cpu        (cpu),
        .cpu_wdata  (cpu_wdata),
        .cpu_addr   (cpu_addr),
        .cpu_rdata  (cpu_rdata),
        .cpu_valid  (cpu_valid),
        .cpu_ren    (cpu_ren),
        .clk        (clk),
        .rst_n      (rst_n)
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
        if (h_drive === 1'b1 && dut.bus_drive === 1'b1) begin
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
            h_io = 1'b0;                    // read direction
            h_drive = 1'b1; h_data = addr[15:0];
            #200;
            host_beat(addr[15:0]);          // beat 0
            host_beat(addr[31:16]);         // beat 1
            h_drive = 1'b0;                 // let go, the FPGA drives next

            #(PCLK_LO); h_pclk = 1'b1;      // beat 2
            #(PCLK_HI/2); data[15:0] = cpu[15:0];
            #(PCLK_HI/2); h_pclk = 1'b0;

            #(PCLK_LO); h_pclk = 1'b1;      // beat 3
            #(PCLK_HI/2); data[31:16] = cpu[15:0];
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
        $dumpfile("output/tb_busV2.vcd");
        $dumpvars(0, tb_busV2);

        #200 rst_n = 1'b1;
        #(GAP);

        // ---- write still works ----
        host_write(32'h1234_5678, 32'hCAFE_F00D);
        chk("write addr", seen_addr, 32'h1234_5678);
        chk("write data", seen_data, 32'hCAFE_F00D);
        chk_int("write valid count", valid_count, 1);
        chk_int("no ren on write", ren_count, 0);

        // ---- read straight after a write (io edge resync) ----
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
        chk_int("ren count", ren_count, 3);

        // ---- write after a read ----
        host_write(32'h8765_4321, 32'h0BAD_C0DE);
        chk("write2 addr", seen_addr, 32'h8765_4321);
        chk("write2 data", seen_data, 32'h0BAD_C0DE);
        chk_int("valid count", valid_count, 2);

        // ---- read must not disturb the stored write data ----
        host_read(32'h0000_0040, rd);
        chk("read4 data", rd, mem_lookup(32'h0000_0040));
        chk("wdata untouched by read", cpu_rdata, 32'h0BAD_C0DE);

        // ---- the RPI stalls in the middle of a burst ----
        // Nothing is timed any more, so a burst must survive the host being
        // descheduled between beats.
        h_drive = 1'b1; h_data = 16'h2222;
        #100; h_io = 1'b1; #100;
        host_beat(16'h2222);        // beat 0, addr lo
        #50000;                     // 50 us of nothing, mid burst
        host_beat(16'h1111);        // beat 1, addr hi
        #17000;
        host_beat(16'h4444);        // beat 2, data lo
        #123000;                    // much longer again
        host_beat(16'h3333);        // beat 3, data hi
        #200; h_io = 1'b0; h_drive = 1'b0;
        #(GAP);
        chk("stalled write addr", seen_addr, 32'h1111_2222);
        chk("stalled write data", seen_data, 32'h3333_4444);
        chk_int("stalled write valid count", valid_count, 3);

        // ---- back to back writes with no gap at all ----
        h_io = 1'b1; h_drive = 1'b1;
        #200;
        host_beat(16'hAAAA); host_beat(16'hBBBB);
        host_beat(16'hCCCC); host_beat(16'hDDDD);   // burst 1 ends
        host_beat(16'h0001); host_beat(16'h0002);
        host_beat(16'h0003); host_beat(16'h0004);   // burst 2, zero gap
        #200; h_io = 1'b0; h_drive = 1'b0;
        #(GAP);
        chk("gapless burst 2 addr", seen_addr, 32'h0002_0001);
        chk("gapless burst 2 data", seen_data, 32'h0004_0003);
        chk_int("gapless valid count", valid_count, 5);

        // ---- FPGA must be off the bus at idle ----
        #(GAP);
        if (cpu[15:0] !== 16'h0000) begin
            $display("FAIL idle: bus is %04h, expected pulldowns to win", cpu[15:0]);
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
