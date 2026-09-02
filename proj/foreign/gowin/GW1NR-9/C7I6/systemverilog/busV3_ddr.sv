module busV3_ddr(
    inout  wire [17:0] cpu,
    input  wire [31:0] cpu_wdata,   // value we send back on a read
    output reg  [31:0] cpu_addr,
    output reg  [31:0] cpu_rdata,   // value we captured on a write
    output reg         cpu_valid,   // one clk strobe, write burst complete
    output reg         cpu_ren,     // one clk strobe, read address is ready
    input  wire        clk,         // FPGA fabric clock
    input  wire        rst_n        // FPGA reset
);

    // Double data rate version of busV2. A beat lands on every pclk edge
    // instead of every rising edge, so io still picks the direction on the
    // first beat but a burst costs half the pclk cycles.
    //
    // io = 1, write, 2 pclk cycles, all 4 beats from the RPI:
    //   edge 0, rise : addr [15:0]
    //   edge 1, fall : addr [31:16]
    //   edge 2, rise : data [15:0]
    //   edge 3, fall : data [31:16]
    //
    // io = 0, read, 3 pclk cycles:
    //   edge 0, rise : addr [15:0]        RPI drives
    //   edge 1, fall : addr [31:16]       RPI drives, then lets go
    //   edge 2, rise : turnaround
    //   edge 3, fall : we take the bus and present data [15:0]
    //   edge 4, rise : RPI samples data [15:0],  we present data [31:16]
    //   edge 5, fall : RPI samples data [31:16], we let go
    //
    // The read costs a whole pclk cycle of turnaround because there is no
    // longer a quiet half cycle to hand the wires over in. That window is
    // also what the fabric gets to answer cpu_ren, so it is a full pclk
    // period rather than the half period busV2 allowed.
    //
    // pclk is fully asynchronous and the RPI may take as long as it likes
    // between edges, including in the middle of a burst. A burst is a fixed
    // number of edges, so its end is what frames it: phase wraps to 0 on the
    // last beat and the next edge is beat 0 of whatever comes next. Nothing
    // is timed, so there is no gap to leave and no stall that can desync us.
    //
    // Both bursts are an even number of edges, so beat 0 always lands on a
    // rising edge. Phase 0 only accepts a rising edge, which keeps that
    // invariant true and lets an io edge pull us back into step.

    // Raw asynchronous signals from the bus
    wire pclk_raw = cpu[16];
    wire io_raw   = cpu[17];

    // Synchronized versions, with clean edge ticks
    wire pclk_rise;
    wire pclk_fall;
    wire io_sync;
    wire io_edge;

    // Synchronise pclk into FPGA clock domain
    sync_edge sync_pclk(
        .clk        (clk),
        .rst_n      (rst_n),
        .async_in   (pclk_raw),
        .sync_out   (),
        .rise       (pclk_rise),
        .fall       (pclk_fall),
        .edge_any   ()
    );

    // Synchronise io into FPGA clock domain, just for now...
    // might remove in future
    sync_edge sync_io(
        .clk        (clk),
        .rst_n      (rst_n),
        .async_in   (io_raw),
        .sync_out   (io_sync),
        .rise       (),
        .fall       (),
        .edge_any   (io_edge)
    );

    wire pclk_edge = pclk_rise | pclk_fall;

    // At DDR the RPI changes the wires halfway between edges, and our edge
    // ticks arrive two clks late, so reading the pads directly would race
    // the next beat. Delay the data by the same two stages as pclk and the
    // sample lands back where the edge was.
    reg [15:0] data_ff1;
    reg [15:0] data_in;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_ff1 <= 16'h0000;
            data_in  <= 16'h0000;
        end else begin
            data_ff1 <= cpu[15:0];
            data_in  <= data_ff1;
        end
    end

    reg [2:0] phase   = 3'd0;
    reg       is_read = 1'b0;

    // Read data we drive back out on edges 3 to 5
    reg [15:0] bus_out   = 16'h0000;
    reg        bus_drive = 1'b0;

    assign cpu[15:0] = bus_drive ? bus_out : 16'hzzzz;

    // Upper bits must ALWAYS be 'z'
    assign cpu[17:16] = 2'bzz;

    // Every pclk edge is a beat, not just the rising ones
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_addr   <= 32'b0;
            cpu_rdata  <= 32'b0;
            cpu_valid  <= 1'b0;
            cpu_ren    <= 1'b0;
            phase      <= 3'd0;
            is_read    <= 1'b0;
            bus_out    <= 16'h0000;
            bus_drive  <= 1'b0;
        end else begin
            cpu_valid <= 1'b0;      // default, strobes are one clk wide
            cpu_ren   <= 1'b0;

            if (io_edge && !pclk_edge) begin
                // io only moves between bursts, so it is a free resync
                phase     <= 3'd0;
                bus_drive <= 1'b0;
            end else if (pclk_edge) begin
                case (phase)
                    3'd0: begin
                        if (pclk_rise) begin        // bursts open on a rise
                            is_read         <= ~io_sync;    // io picks the direction
                            cpu_addr[15:0]  <= data_in;
                            phase           <= 3'd1;
                        end
                    end
                    3'd1: begin
                        cpu_addr[31:16] <= data_in;
                        cpu_ren         <= is_read;     // address done, fetch it
                        phase           <= 3'd2;
                    end
                    3'd2: begin
                        if (!is_read)                   // read spends this edge
                            cpu_rdata[15:0] <= data_in; // on turnaround
                        phase           <= 3'd3;
                    end
                    3'd3: begin
                        if (is_read) begin
                            bus_out     <= cpu_wdata[15:0];
                            bus_drive   <= 1'b1;        // our turn on the wires
                            phase       <= 3'd4;
                        end else begin
                            cpu_rdata[31:16] <= data_in;
                            cpu_valid        <= 1'b1;
                            phase            <= 3'd0;   // write done, ready again
                        end
                    end
                    3'd4: begin
                        bus_out         <= cpu_wdata[31:16];
                        phase           <= 3'd5;
                    end
                    3'd5: begin
                        bus_drive       <= 1'b0;        // let go
                        phase           <= 3'd0;        // read done, ready again
                    end
                    default: begin
                        phase           <= 3'd0;
                        bus_drive       <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule
