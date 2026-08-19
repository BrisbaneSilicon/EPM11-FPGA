module busV2(
    inout  wire [17:0] cpu,
    input  wire [31:0] cpu_wdata,   // value we send back on a read
    output reg  [31:0] cpu_addr,
    output reg  [31:0] cpu_rdata,   // value we captured on a write
    output reg         cpu_valid,   // one clk strobe, write burst complete
    output reg         cpu_ren,     // one clk strobe, read address is ready
    input  wire        clk,         // FPGA fabric clock
    input  wire        rst_n        // FPGA reset
);

    // io picks the direction, sampled on beat 0 of the burst.
    //
    // io = 1, write, all 4 beats come from the RPI:
    //   beat 0 : addr [15:0]
    //   beat 1 : addr [31:16]
    //   beat 2 : data [15:0]
    //   beat 3 : data [31:16]
    //
    // io = 0, read, 2 beats from the RPI then 2 back from us:
    //   beat 0 : addr [15:0]
    //   beat 1 : addr [31:16]
    //   beat 2 : data [15:0]     driven by the FPGA
    //   beat 3 : data [31:16]    driven by the FPGA
    //
    // pclk is fully asynchronous and the RPI may take as long as it likes
    // between beats, including in the middle of a burst. A burst is always 4
    // beats, so its end is what frames it: beat wraps to 0 on the last one
    // and the next pclk is beat 0 of whatever comes next. Nothing is timed,
    // so there is no gap to leave and no stall that can desync us.
    //
    // An io edge is a free resync on top of that, since io only ever moves
    // between bursts.

    // Raw asynchronous signals from the bus
    wire pclk_raw = cpu[16];
    wire io_raw   = cpu[17];

    // Synchronized versions, with clean edge ticks
    wire pclk_sync;
    wire pclk_tick;     // rising edge pulse
    wire pclk_fall;     // falling edge pulse
    wire io_sync;
    wire io_edge;

    // Synchronise pclk into FPGA clock domain
    sync_edge sync_pclk(
        .clk        (clk),
        .rst_n      (rst_n),
        .async_in   (pclk_raw),
        .sync_out   (pclk_sync),
        .rise       (pclk_tick),
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

    wire pclk_edge = pclk_tick | pclk_fall;

    // Our edge ticks arrive two clks after the real pclk edge, so reading the
    // pads directly would only work while the RPI held each beat well past
    // that edge. Delay the data by the same two stages as pclk and the sample
    // lands back where the edge was, whatever the RPI does next.
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

    reg [1:0] beat    = 2'b00;
    reg       is_read = 1'b0;

    // Read data we drive back out on beats 2 and 3
    reg [15:0] bus_out   = 16'h0000;
    reg        bus_drive = 1'b0;

    assign cpu[15:0] = bus_drive ? bus_out : 16'hzzzz;

    // Upper bits must ALWAYS be 'z'
    assign cpu[17:16] = 2'bzz;

    // Use pclk_tick instead of posedge pclk
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_addr   <= 32'b0;
            cpu_rdata  <= 32'b0;
            cpu_valid  <= 1'b0;
            cpu_ren    <= 1'b0;
            beat       <= 2'b00;
            is_read    <= 1'b0;
            bus_out    <= 16'h0000;
            bus_drive  <= 1'b0;
        end else begin
            cpu_valid <= 1'b0;      // default, strobes are one clk wide
            cpu_ren   <= 1'b0;

            if (io_edge && !pclk_edge) begin
                // io only moves between bursts, so it is a free resync
                beat      <= 2'b00;
                bus_drive <= 1'b0;
            end else begin

                if (pclk_tick) begin
                    case (beat)
                        2'b00: begin
                            is_read         <= ~io_sync;    // io picks the direction
                            cpu_addr[15:0]  <= data_in;
                            beat            <= 2'b01;
                        end
                        2'b01: begin
                            cpu_addr[31:16] <= data_in;
                            cpu_ren         <= is_read;     // address done, fetch it
                            beat            <= 2'b10;
                        end
                        2'b10: begin
                            if (!is_read)
                                cpu_rdata[15:0] <= data_in;
                            beat            <= 2'b11;
                        end
                        2'b11: begin
                            if (!is_read) begin
                                cpu_rdata[31:16] <= data_in;
                                cpu_valid        <= 1'b1;
                            end
                            beat            <= 2'b00;       // done, ready again
                        end
                    endcase
                end

                // Change the read data on the falling edge of pclk so it is
                // stable the whole time pclk is high and the RPI samples it.
                // Beat 2 lands here first, which gives the RPI the whole of
                // pclk 2 to let go of the wires before we drive them. Once
                // beat has wrapped to 0 this releases the bus again.
                if (pclk_fall) begin
                    bus_drive <= 1'b0;      // default, stay off the bus

                    if (is_read) begin
                        case (beat)
                            2'b10: begin
                                bus_out   <= cpu_wdata[15:0];
                                bus_drive <= 1'b1;
                            end
                            2'b11: begin
                                bus_out   <= cpu_wdata[31:16];
                                bus_drive <= 1'b1;
                            end
                            default: ;      // address phase, the RPI owns the wires
                        endcase
                    end
                end
            end
        end
    end

endmodule
