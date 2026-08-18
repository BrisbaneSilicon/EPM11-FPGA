
module bus(
    inout  wire [17:0] cpu,
    input  wire [31:0] cpu_wdata,
    output reg  [31:0] cpu_rdata,
    input  wire        clk,      // FPGA fabric clock
    input  wire        rst_n     // FPGA reset
);

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

    reg count = 1'b0;

    // Tri-state driver for lower 16 bits
    assign cpu[15:0] = (io_sync == 1'b0) ?
                       cpu_wdata[(count*16) +: 16] :
                       16'hzzzz;

    // Upper bits must ALWAYS be 'z'
    assign cpu[17:16] = 2'bzz;

    // Use pclk_tick instead of posedge pclk
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_rdata <= 32'b0;
            count     <= 1'b0;
        end else if (pclk_tick) begin
            if (io_sync) begin
                cpu_rdata[(count*16) +: 16] <= cpu[15:0];
            end
            count <= ~count;
        end
    end

endmodule
