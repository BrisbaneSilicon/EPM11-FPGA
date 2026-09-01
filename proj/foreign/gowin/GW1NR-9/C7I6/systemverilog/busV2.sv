// -------------------------------------------------------------------------
// DESCRIPTION :
//
// Master Slave bus. FPGA is the slave, and recieves a wr signal from the master
// (RPI) declaring a read or write operation. This is recieved every time the
// master activates the cpu clk.
//
// -------------------------------------------------------------------------
//
// Here's a general reference:
//
// cpu_wr = 1, write, all 4 beats come from the host:
//      beat 0 : addr [15:0]
//      beat 1 : addr [31:16]
//      beat 2 : data [15:0]
//      beat 3 : data [31:16]
//
// cpu_wr = 0, read, 2 beats from the host then 2 back from us:
//      beat 0 : addr [15:0]
//      beat 1 : addr [31:16]
//      beat 2 : data [15:0]        driven by the FPGA
//      beat 3 : data [31:16]       driven by the FPGA
//
// -------------------------------------------------------------------------

`timescale 1ns/1ps

module busV2
#(
    parameter int pSYNC_STAGES = 2
)
(
    // -------------- FPGA clocking --------------

    input   logic           clk,
    input   logic           srst,


    // -------------- Host wires --------------

    inout   wire    [15:0]  cpu_data_async,
    input   logic           cpu_clk_async,
    input   logic           cpu_wr_async,


    // -------- fabric master --------------------
    // NOTE: named from OUR point of view, so
    // m_wrdata is what we write into the fabric
    // and m_rddata is what it hands back...

    output  logic   [31:0]  m_addr,
    output  logic   [31:0]  m_wrdata,
    output  logic           m_wvalid,
    output  logic           m_ren,
    input   logic   [31:0]  m_rddata,


    // -------------- debug --------------

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

    logic           i_cpu_clk_sync_d;

    logic           i_cpu_wr_sync;
    logic           i_cpu_wr_sync_d;
    logic           i_cpu_wr_edge;

    logic   [pSYNC_STAGES-1:0] [15:0]   i_data_pipe;
    logic   [15:0]                      i_data;

    logic   [1:0]   i_beat;
    logic           i_is_read;

    logic   [15:0]  i_bus_out;
    logic           i_bus_drive;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------



    // -------------------------------
    // SYNCHRONISERS:
    //
    // Firstly, we use the dff_synchroniser to detect the asynchronous cpu clk
    // each cpu clk tick is one of 4 bursts, and the RPI can make execute them
    // manually at different times based on user programming.
    // -------------------------------

    dff_synchroniser #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) dff_synchroniser_cpu_clk_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (i_cpu_clk_sync),

        .async          (cpu_clk_async)
    );

    dff_synchroniser #(
        .pSYNC_STAGES   (pSYNC_STAGES)
    ) dff_synchroniser_cpu_wr_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (i_cpu_wr_sync),

        .async          (cpu_wr_async)
    );

    // Now we use a delayed copy of each synchronised line to detect the
    // edge ticks.

    always @(posedge clk) begin

        i_cpu_clk_sync_d <= i_cpu_clk_sync;
        i_cpu_wr_sync_d  <= i_cpu_wr_sync;

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            i_cpu_clk_sync_d <= 1'b0;
            i_cpu_wr_sync_d  <= 1'b0;
        end
    end

    assign i_cpu_clk_rise = i_cpu_clk_sync & ~i_cpu_clk_sync_d;
    assign i_cpu_clk_fall = ~i_cpu_clk_sync & i_cpu_clk_sync_d;
    assign i_cpu_clk_edge = i_cpu_clk_sync ^ i_cpu_clk_sync_d;

    assign i_cpu_wr_edge  = i_cpu_wr_sync ^ i_cpu_wr_sync_d;



    // -----------------------------------------------------------------
    // BEAT CAPTURE:
    //
    // Now that we can synchronise and detect the edge ticks, we need
    // to account for the delay caused by pSYNC_CHANGES.
    // Easy, we delay the data by exactly the same number of stages.
    // IMPORTANT: a fixed depth would silently drift off the edge as 
    // pSYNC_STAGES is raised.
    // ------------------------------------------------------------------

    integer i_k;
    always @(posedge clk) begin

        i_data_pipe[0] <= cpu_data_async;

        for (i_k = 1; i_k < pSYNC_STAGES; i_k = i_k + 1) begin
            i_data_pipe[i_k] <= i_data_pipe[i_k-1];
        end

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            for (i_k = 0; i_k < pSYNC_STAGES; i_k = i_k + 1) begin
                i_data_pipe[i_k] <= 16'h0000;
            end
        end
    end

    assign i_data = i_data_pipe[pSYNC_STAGES-1];

    assign cpu_data_async = i_bus_drive ? i_bus_out : 16'hzzzz;

    assign dbg_data     = i_data;
    assign dbg_beat     = i_beat;
    assign dbg_is_read  = i_is_read;
    assign dbg_drive    = i_bus_drive;



    // ----------------------------------------------------------------------
    // BURST SEQUENCER:
    //
    // Now we read the wr signal and based on the burst stage we are at
    // handle the data lines.
    // i_beat tracks the burst stage
    // We use the rising and falling edge of the clock to advance the burst
    // stage, and arm the drivers respectively
    // ----------------------------------------------------------------------

    always @(posedge clk) begin
        m_wvalid <= 1'b0;
        m_ren    <= 1'b0;
        if ((i_cpu_wr_edge == 1'b1) && (i_cpu_clk_edge == 1'b0)) begin
            i_beat      <= 2'b00;
            i_bus_drive <= 1'b0;
        end else begin
            // Each beat corresponds to one of 4 burst stages.
            // the first 2 always recieve an address (always read)
            // then the last are dependent on the wr signal for writing or reading
            // In that case the first 2 cases will (when used) always be true.
            if (i_cpu_clk_rise == 1'b1) begin
                case (i_beat)
                    2'b00: begin
                        i_is_read       <= ~i_cpu_wr_sync;
                        m_addr[15:0]    <= i_data;
                        i_beat          <= 2'b01;
                    end

                    2'b01: begin
                        m_addr[31:16]   <= i_data;
                        m_ren           <= i_is_read;
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
                    end
                endcase
            end

            // This is a really important part. On the falling edge,
            // we arm the drivers (if the RPI is reading), this gives the
            // RPI time to stop driving the wires, and time for the FPGA
            // to fetch the data then drive the wires.

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
