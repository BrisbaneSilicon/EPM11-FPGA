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

    inout   reg                 cpu,

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

    input       [31:0]          cpu_addr,
    input       [31:0]          cpu_wdata,
    input       [3:0]           cpu_wstrb,
    output  reg [31:0]          cpu_rdata,
    input                       cpu_valid,
    output  reg                 cpu_ready,


    // -------------- memory --------------

    input       [31:0]          ram_addr,
    input       [31:0]          ram_wdata,
    input       [3:0]           ram_wstrb,
    output  reg [31:0]          ram_rdata,
    input                       ram_valid,
    output  reg                 ram_ready
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



    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------


    // NOTE: CPU
    // Interface
    // ------------------

    // TODO: implement CPU bus...

    assign cpu          = 'z;

    assign cpu_ready    = 1'b1;
    assign cpu_rdata    = 0;


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

    // SRAM/HyperRAM — flatten [0:0][31:0] to [31:0]
    assign i_mbus_sram_addr[0]  = ram_addr;
    assign i_mbus_sram_wdata[0] = ram_wdata;
    assign i_mbus_sram_wstrb[0] = ram_wstrb;
    assign ram_rdata            = i_mbus_sram_rdata[0];
    assign i_mbus_sram_valid[0] = ram_valid;
    assign ram_ready            = i_mbus_sram_ready[0];

endmodule
