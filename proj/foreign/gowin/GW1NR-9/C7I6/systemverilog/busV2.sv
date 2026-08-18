module busV2 #(
    parameter int IDLE_TIMEOUT = 1024    // fabric clocks of pclk silence that ends a burst
)(
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
    // io = 0 is also the idle level, so unlike the write only version it
    // cannot tell us where a burst starts. A burst now starts on the first
    // pclk after the bus has been quiet for IDLE_TIMEOUT fabric clocks.
    // Any io edge resyncs too, which covers a write following a read.

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

    // Quiet bus detector, this is what frames a burst now
    reg [15:0] idle_count = 16'd0;
    wire bus_idle = (idle_count == IDLE_TIMEOUT);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            idle_count <= 16'd0;
        else if (pclk_tick || pclk_fall)
            idle_count <= 16'd0;
        else if (!bus_idle)
            idle_count <= idle_count + 16'd1;
    end

    // Hold the burst in reset while the bus is quiet, but let the pclk that
    // ends the quiet period through as beat 0
    wire frame_reset = (bus_idle | io_edge) & ~pclk_tick;

    reg [1:0] beat       = 2'b00;
    reg       frame_done = 1'b0;
    reg       is_read    = 1'b0;

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
            frame_done <= 1'b0;
            is_read    <= 1'b0;
            bus_out    <= 16'h0000;
            bus_drive  <= 1'b0;
        end else begin
            cpu_valid <= 1'b0;      // default, strobes are one clk wide
            cpu_ren   <= 1'b0;

            if (frame_reset) begin
                // quiet bus, the next pclk is beat 0 of a new burst
                beat       <= 2'b00;
                frame_done <= 1'b0;
                bus_drive  <= 1'b0;
            end else begin

                if (pclk_tick && !frame_done) begin
                    if (beat == 2'b00)
                        is_read <= ~io_sync;    // io picks the direction

                    // the RPI holds each beat for the whole pclk period,
                    // so the wires are quiet when we sample them here
                    if (!beat[1]) begin
                        cpu_addr[beat[0]*16 +: 16] <= cpu[15:0];

                        // address is complete, ask the fabric for the value
                        if (beat == 2'b01 && is_read)
                            cpu_ren <= 1'b1;
                    end else if (!is_read) begin
                        cpu_rdata[beat[0]*16 +: 16] <= cpu[15:0];
                    end

                    if (beat == 2'b11) begin
                        frame_done <= 1'b1; // ignore any extra pclk in this burst
                        if (!is_read)
                            cpu_valid <= 1'b1;
                    end else begin
                        beat <= beat + 2'd1;
                    end
                end

                // Change the read data on the falling edge of pclk so it is
                // stable the whole time pclk is high and the RPI samples it.
                // Beat 2 lands here first, which gives the RPI the whole of
                // pclk 2 to let go of the wires before we drive them.
                if (pclk_fall) begin
                    if (is_read && !frame_done && beat[1]) begin
                        bus_out   <= cpu_wdata[beat[0]*16 +: 16];
                        bus_drive <= 1'b1;
                    end else begin
                        bus_drive <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
