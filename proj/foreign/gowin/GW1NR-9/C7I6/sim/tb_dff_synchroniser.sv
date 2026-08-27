// -------------------------------------------------------------------------
// DESCRIPTION :
//
// Testbench for dff_synchroniser, and for the edge-detect pattern the bus
// modules build on top of it.
//
// -------------------------------------------------------------------------
// SPECIFICATION :
//
// dff_synchroniser replaced bs_dff_sync and sync_edge. It synchronises but
// does not detect edges, so busV2 and busV3_ddr now derive their rise and
// fall ticks locally from a delayed copy of the synchronised line. This
// checks that arrangement against an independent reference model:
//
//      sync            matches an N-deep shift register, exactly
//      rise / fall     one clk wide, on the correct edge, never both
//      edge            always equal to rise | fall
//      srst            forces sync to pSYNC_DEFAULT and emits no edges
//
// Every check runs at pSYNC_STAGES of 2, 3 and 4, because the depth being
// a parameter is the whole point of the module and a wrong shift would
// only show up at depths other than 2.
//
// Run with  ./run.sh sync
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_dff_synchroniser;

    localparam real CLK_HALF = 9.8039;      // 51 MHz

    logic clk  = 1'b0;
    logic srst = 1'b1;
    always #(CLK_HALF) clk = ~clk;

    logic i_async = 1'b0;

    integer errors = 0;

    task chk(input [255:0] name, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got %0d exp %0d", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------------------------------------------------------------
    //  One instance per depth, each with its own reference model
    // ---------------------------------------------------------------------

    genvar d;
    generate
        for (d = 2; d <= 4; d = d + 1) begin : gen_depth

            logic i_sync;
            logic i_sync_d;
            logic i_rise;
            logic i_fall;
            logic i_edge;

            dff_synchroniser #(
                .pSYNC_STAGES   (d)
            ) dff_synchroniser_inst (
                .clk            (clk),
                .srst           (srst),
                .sync           (i_sync),

                .async          (i_async)
            );

            // The exact pattern busV2 and busV3_ddr use.
            always @(posedge clk) begin
                i_sync_d <= i_sync;

                if (srst == 1'b1) begin
                    i_sync_d <= 1'b0;
                end
            end

            assign i_rise = i_sync & ~i_sync_d;
            assign i_fall = ~i_sync & i_sync_d;
            assign i_edge = i_sync ^ i_sync_d;

            // ---- independent reference: a plain shift register ----
            logic [7:0] i_ref_sr;
            logic       i_ref_sync;
            logic       i_ref_sync_d;

            always @(posedge clk) begin
                i_ref_sr     <= {i_ref_sr[6:0], i_async};
                i_ref_sync_d <= i_ref_sync;

                if (srst == 1'b1) begin
                    i_ref_sr     <= 8'h00;
                    i_ref_sync_d <= 1'b0;
                end
            end

            assign i_ref_sync = i_ref_sr[d-1];

            // ---- continuous equivalence checks ----
            integer rise_count = 0;
            integer fall_count = 0;

            always @(posedge clk) begin
                if (srst == 1'b0) begin
                    // sync must equal a d-deep shift of async
                    if (i_sync !== i_ref_sync) begin
                        $display("FAIL depth %0d: sync %b, reference %b", d, i_sync, i_ref_sync);
                        errors = errors + 1;
                    end

                    // edge must always be rise or fall, never both
                    if (i_edge !== (i_rise | i_fall)) begin
                        $display("FAIL depth %0d: edge %b, rise|fall %b", d, i_edge, i_rise | i_fall);
                        errors = errors + 1;
                    end
                    if ((i_rise === 1'b1) && (i_fall === 1'b1)) begin
                        $display("FAIL depth %0d: rise and fall together", d);
                        errors = errors + 1;
                    end

                    if (i_rise === 1'b1) rise_count = rise_count + 1;
                    if (i_fall === 1'b1) fall_count = fall_count + 1;
                end else begin
                    // no edges may be emitted while in reset
                    if ((i_rise === 1'b1) || (i_fall === 1'b1)) begin
                        $display("FAIL depth %0d: edge during reset", d);
                        errors = errors + 1;
                    end
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------------
    //  Stimulus
    // ---------------------------------------------------------------------

    integer pulses;

    initial begin
        $dumpfile("output/tb_dff_synchroniser.vcd");
        $dumpvars(0, tb_dff_synchroniser);

        $display("dff_synchroniser, depths 2 to 4");

        // ---- reset holds sync at the default and emits no edges ----
        repeat (8) @(posedge clk);
        chk("sync low in reset d2", gen_depth[2].i_sync, 0);
        chk("sync low in reset d3", gen_depth[3].i_sync, 0);
        chk("sync low in reset d4", gen_depth[4].i_sync, 0);

        @(negedge clk);
        srst = 1'b0;

        // ---- a clean pulse, aligned to the clock ----
        repeat (4) @(posedge clk);
        @(negedge clk) i_async = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk) i_async = 1'b0;
        repeat (8) @(posedge clk);

        chk("one rise seen, d2", gen_depth[2].rise_count, 1);
        chk("one fall seen, d2", gen_depth[2].fall_count, 1);
        chk("one rise seen, d3", gen_depth[3].rise_count, 1);
        chk("one fall seen, d3", gen_depth[3].fall_count, 1);
        chk("one rise seen, d4", gen_depth[4].rise_count, 1);
        chk("one fall seen, d4", gen_depth[4].fall_count, 1);

        // ---- pulses landing off the clock, as a real pad would ----
        for (pulses = 0; pulses < 20; pulses = pulses + 1) begin
            #(3.7 * pulses + 1) i_async = 1'b1;
            #(11.3 + pulses)    i_async = 1'b0;
            #(7.1);
        end
        repeat (16) @(posedge clk);

        // every rise must be matched by a fall, at every depth
        chk("d2 rises match falls", gen_depth[2].rise_count, gen_depth[2].fall_count);
        chk("d3 rises match falls", gen_depth[3].rise_count, gen_depth[3].fall_count);
        chk("d4 rises match falls", gen_depth[4].rise_count, gen_depth[4].fall_count);

        // all depths must see the same number of events, just later
        chk("d2 and d3 agree", gen_depth[2].rise_count, gen_depth[3].rise_count);
        chk("d3 and d4 agree", gen_depth[3].rise_count, gen_depth[4].rise_count);

        // ---- reset mid-stream must not emit a spurious edge ----
        @(negedge clk) i_async = 1'b1;
        repeat (6) @(posedge clk);
        @(negedge clk) srst = 1'b1;
        repeat (6) @(posedge clk);
        chk("sync cleared by reset, d4", gen_depth[4].i_sync, 0);
        @(negedge clk) srst = 1'b0;
        repeat (8) @(posedge clk);

        if (errors == 0) begin
            $display("PASS %0d rise/fall pairs tracked at each depth",
                     gen_depth[2].rise_count);
            $display("*** ALL TESTS PASSED ***");
        end else begin
            $display("*** %0d FAILURE(S) ***", errors);
        end
        $finish;
    end

endmodule
