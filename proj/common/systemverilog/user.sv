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

module user (
    input               sysclk,
    input               sysclk_resetn,

    input               microsecond_tick,
    input               millisecond_tick,
    input               second_tick,

    inout       [16:1]  io,
        // NOTE: numbering to match FPGA
        // bus Pins...


    // -------------- cpu --------------

    output  reg [31:0]  cpu_addr,
    output  reg [31:0]  cpu_wdata,
    output  reg [3:0]   cpu_wstrb,
    input       [31:0]  cpu_rdata,
    output  reg         cpu_valid,
    input               cpu_ready,


    // -------------- memory --------------

    output  reg [31:0]  ram_addr,
    output  reg [31:0]  ram_wdata,
    output  reg [3:0]   ram_wstrb,
    input       [31:0]  ram_rdata,
    output  reg         ram_valid,
    input               ram_ready,


    // -------------- example probe --------------

    output  reg [15:0]  probe
);


    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    // NOTE: add signal definitions here


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    // NOTE: add logic here


    // NOTE: demonstration - feel free to remove

    assign io = 'z;
        // NOTE: entire bus as input...

    always @(posedge sysclk) begin
        probe[15:0] <= io[16:1];
            // NOTE: default

        if (sysclk_resetn == 1'b0) begin
            probe <= 0;
        end
    end

endmodule
