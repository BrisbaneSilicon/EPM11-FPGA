module bus(
    inout  wire [17:0] cpu,
    input  wire [31:0] cpu_wdata,   // for the read direction, not used yet
    output reg  [31:0] cpu_addr,
    output reg  [31:0] cpu_rdata,
    output reg         cpu_valid,   // one clk strobe, burst complete
    input  wire        clk,         // FPGA fabric clock
    input  wire        rst_n        // FPGA reset
);

    // A write burst is 4 pclk cycles:
    //   beat 0 : addr [15:0]
    //   beat 1 : addr [31:16]
    //   beat 2 : data [15:0]
    //   beat 3 : data [31:16]
    // io high frames the burst, the RPI raises it before beat 0
    // and drops it after beat 3.

    // Raw asynchronous signals from the bus
    wire pclk_raw = cpu[16];
    wire io_raw   = cpu[17];

    // Synchronized versions
    wire pclk_sync;
    wire io_sync;

    // Synchronise pclk into FPGA clock domain
    dff_sync sync_pclk(.clk(clk), .rst_n(rst_n), .async_in(pclk_raw), .sync_out(pclk_sync));

    // Synchronise io into FPGA clock domain, just for now... 
    // might remove in future
    dff_sync sync_io(.clk(clk), .rst_n(rst_n), .async_in(io_raw), .sync_out(io_sync));

    // Edge detect pclk_sync to create a clean tick
    reg pclk_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pclk_d <= 1'b0;
        else
            pclk_d <= pclk_sync;
    end

    wire pclk_tick = pclk_sync & ~pclk_d;   // rising edge pulse

    reg [1:0] beat       = 2'b00;
    reg       frame_done = 1'b0;

    // The FPGA never drives the bus during a write, and idle has to be
    // 'z as well or we fight the RPI while it sets up beat 0
    assign cpu[15:0] = 16'hzzzz;

    // Upper bits must ALWAYS be 'z'
    assign cpu[17:16] = 2'bzz;

    // Use pclk_tick instead of posedge pclk
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_addr   <= 32'b0;
            cpu_rdata  <= 32'b0;
            cpu_valid  <= 1'b0;
            beat       <= 2'b00;
            frame_done <= 1'b0;
        end else begin
            cpu_valid <= 1'b0;      // default, strobe is one clk wide

            if (!io_sync) begin
                // idle, hold the frame in reset so every burst
                // starts aligned on beat 0
                beat       <= 2'b00;
                frame_done <= 1'b0;
            end else if (pclk_tick && !frame_done) begin
                // the RPI holds each beat for the whole pclk period,
                // so the wires are quiet when we sample them here
                if (beat[1])
                    cpu_rdata[beat[0]*16 +: 16] <= cpu[15:0];
                else
                    cpu_addr[beat[0]*16 +: 16]  <= cpu[15:0];

                if (beat == 2'b11) begin
                    frame_done <= 1'b1; // ignore any extra pclk in this frame
                    cpu_valid  <= 1'b1;
                end else begin
                    beat <= beat + 2'd1;
                end
            end
        end
    end

endmodule
