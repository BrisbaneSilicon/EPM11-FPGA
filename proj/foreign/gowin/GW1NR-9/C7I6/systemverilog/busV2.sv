
`timescale 1ns/1ps

module busV2
#(
    parameter int pSYNC_STAGES = 2
)
(
    // ---------------- clocking ----------------

    input   logic           clk,
    input   logic           srst,

    // ---------------- host bus, asynchronous ----------------
    // NOTE: only the data lines are shared. The
    // clock and direction are driven by the host
    // alone, so they are plain inputs rather than
    // tri-stated wires we never drive.

    inout   wire    [15:0]  cpu_data_async,
    input   logic           cpu_clk_async,
    input   logic           cpu_wr_async,

    // ---------------- fabric master ----------------
    // NOTE: named from OUR point of view, so
    // m_wrdata is what we write into the fabric
    // and m_rddata is what it hands back.

    output  logic   [31:0]  m_addr,
    output  logic   [31:0]  m_wrdata,
    output  logic           m_wvalid,
        // NOTE: one clk strobe, write burst complete
    output  logic           m_ren,
        // NOTE: one clk strobe, read address is ready
    input   logic   [31:0]  m_rddata,

    // ---------------- debug ----------------
    // NOTE: observation only. Nothing here feeds
    // back into the burst logic, so leaving these
    // unconnected changes nothing.

    output  logic   [15:0]  dbg_data,
    output  logic   [1:0]   dbg_beat,
    output  logic           dbg_is_read,
    output  logic           dbg_drive
);

    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    logic           i_cpu_clk_sync;
    logic           i_cpu_clk_rise;
    logic           i_cpu_clk_fall;
    logic           i_cpu_clk_edge;

    logic           i_cpu_wr_sync;
    logic           i_cpu_wr_edge;

    logic   [15:0]  i_data_ff1;
    logic   [15:0]  i_data;

    logic   [1:0]   i_beat;
    logic           i_is_read;

    logic   [15:0]  i_bus_out;
    logic           i_bus_drive;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    sync_edge #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) sync_edge_cpu_clk_inst (
        .clk            (clk),
        .srst           (srst),

        .sync           (i_cpu_clk_sync),
        .rise           (i_cpu_clk_rise),
        .fall           (i_cpu_clk_fall),
        .edge_any       (),

        .async          (cpu_clk_async)
    );

    sync_edge #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) sync_edge_cpu_wr_inst (
        .clk            (clk),
        .srst           (srst),

        .sync           (i_cpu_wr_sync),
        .rise           (),
        .fall           (),
        .edge_any       (i_cpu_wr_edge),

        .async          (cpu_wr_async)
    );

    assign i_cpu_clk_edge = i_cpu_clk_rise | i_cpu_clk_fall;

    // Our edge ticks arrive pSYNC_STAGES clks after the real cpu_clk edge,
    // so reading the pads directly would only work while the host held each
    // beat well past that edge. Delay the data by the same stages and the
    // sample lands back where the edge was, whatever the host does next.

    always @(posedge clk) begin

        i_data_ff1  <= cpu_data_async;
        i_data      <= i_data_ff1;

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            i_data_ff1  <= 16'h0000;
            i_data      <= 16'h0000;
        end
    end

    assign cpu_data_async = i_bus_drive ? i_bus_out : 16'hzzzz;

    assign dbg_data     = i_data;
    assign dbg_beat     = i_beat;
    assign dbg_is_read  = i_is_read;
    assign dbg_drive    = i_bus_drive;

    always @(posedge clk) begin

        m_wvalid <= 1'b0;
            // NOTE: default, strobes are one clk wide
        m_ren    <= 1'b0;

        if ((i_cpu_wr_edge == 1'b1) && (i_cpu_clk_edge == 1'b0)) begin
            // cpu_wr only moves between bursts, so it is a free resync
            i_beat      <= 2'b00;
            i_bus_drive <= 1'b0;
        end else begin

            if (i_cpu_clk_rise == 1'b1) begin
                case (i_beat)
                    2'b00: begin
                        i_is_read       <= ~i_cpu_wr_sync;
                            // NOTE: cpu_wr picks the direction
                        m_addr[15:0]    <= i_data;
                        i_beat          <= 2'b01;
                    end

                    2'b01: begin
                        m_addr[31:16]   <= i_data;
                        m_ren           <= i_is_read;
                            // NOTE: address done, fetch it
                        i_beat          <= 2'b10;
                    end

                    2'b10: begin
                        if (i_is_read == 1'b0) begin
                            m_wrdata[15:0] <= i_data;
                        end
                        i_beat          <= 2'b11;
                    end

                    default: begin
                        if (i_is_read == 1'b0) begin
                            m_wrdata[31:16] <= i_data;
                            m_wvalid        <= 1'b1;
                        end
                        i_beat          <= 2'b00;
                            // NOTE: done, ready again
                    end
                endcase
            end

            // Change the read data on the falling edge of cpu_clk so it is
            // stable the whole time cpu_clk is high and the host samples
            // it. Beat 2 lands here first, which gives the host the whole
            // of cpu_clk 2 to let go of the wires before we drive them.
            // Once beat has wrapped to 0 this releases the bus again.

            if (i_cpu_clk_fall == 1'b1) begin
                i_bus_drive <= 1'b0;
                    // NOTE: default, stay off the bus

                if (i_is_read == 1'b1) begin
                    case (i_beat)
                        2'b10: begin
                            i_bus_out   <= m_rddata[15:0];
                            i_bus_drive <= 1'b1;
                        end

                        2'b11: begin
                            i_bus_out   <= m_rddata[31:16];
                            i_bus_drive <= 1'b1;
                        end

                        default: ;
                            // NOTE: address phase, the
                            // host owns the wires
                    endcase
                end
            end
        end

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            m_addr      <= 32'h0000_0000;
            m_wrdata    <= 32'h0000_0000;
            m_wvalid    <= 1'b0;
            m_ren       <= 1'b0;
            i_beat      <= 2'b00;
            i_is_read   <= 1'b0;
            i_bus_out   <= 16'h0000;
            i_bus_drive <= 1'b0;
        end
    end

endmodule
