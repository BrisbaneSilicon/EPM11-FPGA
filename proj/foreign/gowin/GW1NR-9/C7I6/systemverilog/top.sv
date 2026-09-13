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
// -------------------------------------------------------------------------
// SPECIFICATION :
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module top #(
    parameter reg   [(8*VERSION_CHARS)-1:0]     VERSION,
    parameter int                               CLK_FREQUENCY_MHZ,
    parameter int                               PUSHBUTTON0_AS_RESET
) (

    // ---------------- pads ----------------

    input                       clk_27Mhz,

    input                       user_pushbutton0_n,
    input                       user_pushbutton1_n,

    output  reg                 led,

    inout   wire    [15:0]      cpu_data_async,
    input                       cpu_clk_async,
    input                       cpu_wr_async,

    output  [CS_WIDTH-1:0]      psram_ck,
    output  [CS_WIDTH-1:0]      psram_ck_n,
    inout   [CS_WIDTH-1:0]      psram_rwds,
    inout   [DQ_WIDTH-1:0]      psram_dq,
    output  [CS_WIDTH-1:0]      psram_reset_n,
    output  [CS_WIDTH-1:0]      psram_cs_n,


    // -------------- fabric --------------

    output  reg                 sysclk,
    output  reg                 sysclk_resetn,

    output  reg                 microsecond_tick,
    output  reg                 millisecond_tick,
    output  reg                 second_tick,

    output reg  [8:0]           microsecond_div_counter,
    output reg  [19:0]          millisecond_div_counter,
    output reg  [11:0]          millisecond_counter,


    // -------------- cpu --------------

    output  reg [31:0]          cpu_addr,
    output  reg [31:0]          cpu_wdata,
    output  reg [3:0]           cpu_wstrb,
    input       [31:0]          cpu_rdata,
    output  reg                 cpu_valid,
    input                       cpu_ready,


    // -------------- memory --------------

    input       [31:0]          ram_addr,
    input       [31:0]          ram_wdata,
    input       [3:0]           ram_wstrb,
    output  reg [31:0]          ram_rdata,
    input                       ram_valid,
    output  reg                 ram_ready,


    // -------------- bus monitor --------------

    output      [31:0]          bus_addr,
    output      [31:0]          bus_data,
    output                      bus_write,
    output                      bus_done,
    output      [15:0]          bus_pin_data,
    output                      bus_pin_clk,
    output                      bus_pin_wr
);
localparam int DQ_WIDTH         = 16;
localparam int CS_WIDTH         = 2;
localparam int VERSION_CHARS    = 36;
localparam int MAX_IO_PER_CORE  = 16;
localparam int CLK_FREQUENCY_HZ = CLK_FREQUENCY_MHZ * 1000000;


    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    wire                    i_sysclk;
    wire                    i_sysclk_p;
    reg                     i_sysclk_pll_lock;
    reg                     i_sysclk_power_on_resetn;
    reg                     i_sysclk_resetn;
    reg                     i_sysclk_ce          = 1'b0;
    reg     [1:0]           i_sysclk_ce_counter  = 0;

    reg                     i_soft_rstn_p3;
    reg                     i_soft_rstn_p2;
    reg                     i_soft_rstn_p1;
    reg                     i_soft_rstn_p0;
    reg                     i_soft_reset_n;

    reg                     i_led;

    wire    [0:0] [31:0]    i_mbus_sram_addr;
    wire    [0:0] [31:0]    i_mbus_sram_wdata;
    wire    [0:0] [3:0]     i_mbus_sram_wstrb;
    reg     [0:0] [31:0]    i_mbus_sram_rdata;
    wire    [0:0]           i_mbus_sram_valid;
    reg     [0:0]           i_mbus_sram_ready;

    reg                     i_cpu_wstrb;

    wire    [31:0]          i_cpu_m_addr;
    wire    [31:0]          i_cpu_m_wdata;
    wire    [3:0]           i_cpu_m_wstrb;
    wire    [31:0]          i_cpu_m_rdata;
    wire                    i_cpu_m_valid;
    wire                    i_cpu_m_ready;



    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------


    // -------------------------------------------------
    // RPI-FPGA BUS:
    //
    // The RPI is the master, the FPGA is the slave.
    //
    // -------------------------------------------------

    cpu_bus cpu_bus_inst (
        .clk            (i_sysclk),
        .srst           (~i_soft_reset_n),

        .cpu_data_async (cpu_data_async),
        .cpu_clk_async  (cpu_clk_async),
        .cpu_wr_async   (cpu_wr_async),

        .cpu_data_sync  (bus_pin_data),
        .cpu_clk_sync   (bus_pin_clk),
        .cpu_wr_sync    (bus_pin_wr),

        .m_addr         (i_cpu_m_addr),
        .m_wdata        (i_cpu_m_wdata),
        .m_wstrb        (i_cpu_wstrb),
        .m_rdata        (i_cpu_m_rdata),
        .m_valid        (i_cpu_m_valid),
        .m_ready        (i_cpu_m_ready)
    );

    assign i_cpu_m_wstrb = { i_cpu_wstrb, i_cpu_wstrb,
                                i_cpu_wstrb,  i_cpu_wstrb };


    // -------------------------------------------------
    // CPU BUS -> MEMORY:
    //
    // The address the RPI sends is an address in the FPGA
    // memory, so 'ram_memory_Inst' owns the whole space
    // and answers every transaction. No decode.
    //
    // NOTE: 'ram_memory' only decodes address bits [21:2],
    // so the space aliases every 4 MB - the map inside it
    // is 32 kB of SRAM at addr[14:0], HyperRAM above that,
    // and anything higher wraps back into that window.
    //
    // -------------------------------------------------

    assign i_mbus_sram_addr[0]  = i_cpu_m_addr;
    assign i_mbus_sram_wdata[0] = i_cpu_m_wdata;
    assign i_mbus_sram_wstrb[0] = i_cpu_m_wstrb;
    assign i_mbus_sram_valid[0] = i_cpu_m_valid;

    assign i_cpu_m_rdata        = i_mbus_sram_rdata[0];
    assign i_cpu_m_ready        = i_mbus_sram_ready[0];


    // NOTE: the same request is still presented to the
    // fabric, so user.sv - and 'cpu_bus_test' in a '-t'
    // build - can watch the traffic and latch it. The
    // memory is what answers, so the 'cpu_rdata' and
    // 'cpu_ready' coming back from the fabric are
    // deliberately not used here...

    assign cpu_addr             = i_cpu_m_addr;
    assign cpu_wdata            = i_cpu_m_wdata;
    assign cpu_wstrb            = i_cpu_m_wstrb;
    assign cpu_valid            = i_cpu_m_valid;


    // -------------------------------------------------
    // BUS MONITOR:
    //
    // A read-only copy of every transaction, for debug.
    // 'bus_data' is the value written or read back, and
    // 'bus_done' is high for one clk as each one completes.
    // 'bus_pin_*' are the bus pins as 'cpu_bus' samples them.
    //
    // -------------------------------------------------

    assign bus_addr             = i_cpu_m_addr;
    assign bus_data             = i_cpu_wstrb ? i_cpu_m_wdata : i_cpu_m_rdata;
    assign bus_write            = i_cpu_wstrb;
    assign bus_done             = i_cpu_m_valid & i_cpu_m_ready;


    
    // NOTE: HyperRAM
    // ------------------

    ram_memory #(
        .IF                     (1),

        .CLK_FREQ_HZ            (CLK_FREQUENCY_HZ),
        .XIP_FIFO_DEPTH_WORDS   (8)
    ) ram_memory_Inst (
        .clk                    (i_sysclk),
        .clk_p                  (i_sysclk_p),

        .clk_resetn             (i_soft_reset_n),

        .saxis_mem_addr         (i_mbus_sram_addr),
        .saxis_mem_wdata        (i_mbus_sram_wdata),
        .saxis_mem_wstrb        (i_mbus_sram_wstrb),
        .saxis_mem_rdata        (i_mbus_sram_rdata),
        .saxis_mem_valid        (i_mbus_sram_valid),
        .saxis_mem_ready        (i_mbus_sram_ready),

        .O_psram_ck             (psram_ck),
        .O_psram_ck_n           (psram_ck_n),
        .IO_psram_rwds          (psram_rwds),
        .IO_psram_dq            (psram_dq),
        .O_psram_reset_n        (psram_reset_n),
        .O_psram_cs_n           (psram_cs_n)
    );


    // NOTE: Leds
    // Related
    // ------------

    always @(posedge i_sysclk) begin
        if (second_tick == 1'b1) begin
            i_led <= ~i_led;
                // NOTE: heartbeat
        end
    end
    assign led = i_led;


    // NOTE: Timer
    // Related
    // ------------

    always @(posedge i_sysclk) begin
        if (i_soft_reset_n == 1'b0) begin
            microsecond_div_counter <= 0;
            millisecond_div_counter <= 0;
            millisecond_counter     <= 0;

            second_tick             <= 1'b0;
            millisecond_tick        <= 1'b0;
            microsecond_tick        <= 1'b0;
        end else begin
            // defaults
            second_tick         <= 1'b0;
            millisecond_tick    <= 1'b0;
            microsecond_tick    <= 1'b0;

            if (millisecond_div_counter == 0) begin
                millisecond_div_counter <= (CLK_FREQUENCY_HZ/1000)-1;
                millisecond_tick        <= 1'b1;
            end else begin
                millisecond_div_counter <= millisecond_div_counter - 1;
            end

            if (microsecond_div_counter == 0) begin
                microsecond_div_counter <= (CLK_FREQUENCY_HZ/1000000)-1;
                microsecond_tick        <= 1'b1;
            end else begin
                microsecond_div_counter <= microsecond_div_counter - 1;
            end

            if (millisecond_tick == 1'b1) begin
                if (millisecond_counter == 1000-1) begin
                    second_tick <= 1'b1;

                    millisecond_counter <= 0;
                end else begin
                    millisecond_counter <= millisecond_counter + 1;
                end
            end
        end
    end


    // NOTE: Reset
    // Related
    // ------------

    rst_sync rst_sync_inst (
        .clk        (i_sysclk),
        .ext_resetn (i_sysclk_pll_lock),

        .resetn     (i_sysclk_power_on_resetn)
    );

    generate
        if (PUSHBUTTON0_AS_RESET) begin
            assign i_soft_rstn_p3 = i_sysclk_power_on_resetn & user_pushbutton0_n;
        end else begin
            assign i_soft_rstn_p3 = i_sysclk_power_on_resetn;
        end
    endgenerate

    always @(posedge i_sysclk) begin
        // NOTE: allow duplication
        // in PAR stage of high-
        // fanout net.
        // -----------------

        i_soft_rstn_p2 <= i_soft_rstn_p3;
        i_soft_rstn_p1 <= i_soft_rstn_p2;
        i_soft_rstn_p0 <= i_soft_rstn_p1;
        i_soft_reset_n <= i_soft_rstn_p0;
    end


    // NOTE: clocking
    // related
    // ------------------

    generate
        if (CLK_FREQUENCY_HZ == 51000000) begin
            clk51mhz clk51mhz_inst (
                .clkin_27Mhz    (clk_27Mhz),

                .lock           (i_sysclk_pll_lock),
                .clkout         (i_sysclk),
                .clkoutp        (i_sysclk_p)
            );
        end
        if (CLK_FREQUENCY_HZ == 66000000) begin
            clk66mhz clk66mhz_inst (
                .clkin_27Mhz    (clk_27Mhz),

                .lock           (i_sysclk_pll_lock),
                .clkout         (i_sysclk),
                .clkoutp        (i_sysclk_p)
            );
        end
        if (CLK_FREQUENCY_HZ == 75000000) begin
            clk75mhz clk75mhz_inst (
                .clkin_27Mhz    (clk_27Mhz),

                .lock           (i_sysclk_pll_lock),
                .clkout         (i_sysclk),
                .clkoutp        (i_sysclk_p)
            );
        end
        if (CLK_FREQUENCY_HZ == 81000000) begin
            clk81mhz clk81mhz_inst (
                .clkin_27Mhz    (clk_27Mhz),

                .lock           (i_sysclk_pll_lock),
                .clkout         (i_sysclk),
                .clkoutp        (i_sysclk_p)
            );
        end
        if (CLK_FREQUENCY_HZ == 87000000) begin
            clk87mhz clk87mhz_inst (
                .clkin_27Mhz    (clk_27Mhz),

                .lock           (i_sysclk_pll_lock),
                .clkout         (i_sysclk),
                .clkoutp        (i_sysclk_p)
            );
        end
    endgenerate

    assign sysclk        = i_sysclk;
    assign sysclk_resetn = i_soft_reset_n;


    // -------------- memory fabric assignments --------------

    // NOTE: the memory is now owned by the CPU bus (see
    // 'CPU ADDRESS DECODE' above), which drives
    // 'i_mbus_sram_*' directly. That leaves user.sv's own
    // memory master with nowhere to go, so it is tied off
    // here rather than left floating - user.sv reads back
    // zero and never sees 'ready'.
    //
    // To give user.sv the memory back alongside the CPU,
    // build 'ram_memory' with IF(2) and put user.sv on
    // interface 1: the arbiter and its round-robin
    // priority scheme are already in that module, and
    // note that IF(2) also splits the SRAM into two 16 kB
    // halves rather than one 32 kB block.

    assign ram_rdata            = 32'h0000_0000;
    assign ram_ready            = 1'b0;

endmodule
