`timescale 1ns/1ps

module tb_bus;

    // 51 MHz fabric clock
    localparam real CLK_HALF = 9.8039;

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;

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

    // pull downs, as per the .cst
    pulldown pd [17:0] (cpu);

    wire [31:0] cpu_addr;
    wire [31:0] cpu_rdata;
    wire        cpu_valid;

    bus dut (
        .cpu        (cpu),
        .cpu_wdata  (32'hDEAD_BEEF),
        .cpu_addr   (cpu_addr),
        .cpu_rdata  (cpu_rdata),
        .cpu_valid  (cpu_valid),
        .clk        (clk),
        .rst_n      (rst_n)
    );

    integer errors = 0;
    integer valid_count = 0;

    // latch what the fabric would see on the strobe
    reg [31:0] seen_addr, seen_data;
    always @(posedge clk) begin
        if (cpu_valid) begin
            seen_addr   <= cpu_addr;
            seen_data   <= cpu_rdata;
            valid_count <= valid_count + 1;
        end
    end

    // ---------------- host model ----------------
    // Pclk period ~ 500 ns (2 MHz), deliberately not
    // related to the fabric clock.
    parameter PCLK_LO = 250;
    parameter PCLK_HI = 250;

    task host_beat(input [15:0] value);
        begin
            h_data  = value;
            h_drive = 1'b1;
            #(PCLK_LO);
            h_pclk = 1'b1;
            #(PCLK_HI);
            h_pclk = 1'b0;
        end
    endtask

    task host_write(input [31:0] addr, input [31:0] data);
        begin
            h_drive = 1'b1;
            h_data  = addr[15:0];
            #100;
            h_io = 1'b1;        // open the frame
            #100;
            host_beat(addr[15:0]);
            host_beat(addr[31:16]);
            host_beat(data[15:0]);
            host_beat(data[31:16]);
            #200;
            h_io    = 1'b0;     // close the frame
            h_drive = 1'b0;
            #500;
        end
    endtask

    task check(input [31:0] exp_addr, input [31:0] exp_data, input integer exp_valids, input [255:0] name);
        begin
            if (seen_addr !== exp_addr || seen_data !== exp_data || valid_count !== exp_valids) begin
                $display("FAIL %0s: addr=%08h (exp %08h) data=%08h (exp %08h) valids=%0d (exp %0d)",
                         name, seen_addr, exp_addr, seen_data, exp_data, valid_count, exp_valids);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: addr=%08h data=%08h", name, seen_addr, seen_data);
            end
        end
    endtask

    initial begin
        $dumpfile("output/tb_bus.vcd");
        $dumpvars(0, tb_bus);

        #200 rst_n = 1'b1;
        #500;

        host_write(32'h1234_5678, 32'hCAFE_F00D);
        check(32'h1234_5678, 32'hCAFE_F00D, 1, "single write");

        host_write(32'h0000_0004, 32'h0000_0001);
        check(32'h0000_0004, 32'h0000_0001, 2, "back to back write");

        host_write(32'hFFFF_FFFF, 32'hFFFF_FFFF);
        check(32'hFFFF_FFFF, 32'hFFFF_FFFF, 3, "all ones");

        // extra Pclk pulses inside a frame must be ignored
        h_drive = 1'b1;
        h_data  = 16'h1111;
        #100; h_io = 1'b1; #100;
        host_beat(16'h1111);
        host_beat(16'h2222);
        host_beat(16'h3333);
        host_beat(16'h4444);
        host_beat(16'hBAAD);   // stray 5th
        host_beat(16'hBAAD);   // stray 6th
        #200; h_io = 1'b0; h_drive = 1'b0; #500;
        check(32'h2222_1111, 32'h4444_3333, 4, "stray pclk ignored");

        // a truncated frame must not strobe, and must not
        // corrupt the alignment of the next one
        h_drive = 1'b1; h_data = 16'hAAAA;
        #100; h_io = 1'b1; #100;
        host_beat(16'hAAAA);
        host_beat(16'hBBBB);
        #200; h_io = 1'b0; h_drive = 1'b0; #500;
        check(32'h2222_1111, 32'h4444_3333, 4, "aborted frame, no strobe");

        host_write(32'h8765_4321, 32'h0BAD_C0DE);
        check(32'h8765_4321, 32'h0BAD_C0DE, 5, "realign after abort");

        if (errors == 0) $display("\n*** ALL TESTS PASSED ***");
        else             $display("\n*** %0d FAILURE(S) ***", errors);
        $finish;
    end

endmodule
