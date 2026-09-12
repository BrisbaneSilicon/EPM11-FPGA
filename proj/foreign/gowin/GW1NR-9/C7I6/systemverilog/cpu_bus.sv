`timescale 1ns/1ps

module cpu_bus #(
    parameter int SYNC_STAGES = 2
) (
    // -------------- FPGA clocking --------------

    input   logic           clk,
    input   logic           srst,


    // -------------- Host wires --------------

    inout   wire    [15:0]  cpu_data_async,
    input   logic           cpu_clk_async,
    input   logic           cpu_wr_async,


    // -------- fabric master --------------------
    // NOTE: named from OUR point of view, so
    // m_wdata is what we write into the fabric
    // and m_rdata is what it hands back...

    output  logic   [31:0]  m_addr,
    output  logic   [31:0]  m_wdata,
    output  logic           m_wstrb,
    input   logic   [31:0]  m_rdata,
    output  logic           m_valid,
    input   logic           m_ready
        // REVISIT: this module currently constrains
        // 'm_ready', such that it must be asserted
        // within a certain interval after 'm_valid'
        // asserts (depending upon read/write) otherwise
        // the transaction will fail...
);


    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    logic           i_cpu_clk;
    logic           i_cpu_clk_d1;
    logic           i_cpu_clk_rise;
    logic           i_cpu_clk_fall;
    logic           i_cpu_clk_edge;

    logic           i_cpu_wr;
    logic           i_cpu_wr_d1;
    logic           i_cpu_wr_edge;

    logic   [1:0]   i_transaction;
    logic           i_wr_transaction;

    logic   [15:0]  i_bus_out;
    logic           i_bus_drive;


    // ----------------------------------------------
    //  Implementation
    // ----------------------------------------------

    assign cpu_data_async = i_bus_drive ? i_bus_out : 16'hzzzz;


    // NOTE: synchronize cpu
    // strobes to the 'clk' domain...
    // -------------------------------

    dff_synchroniser #(
        .SYNC_STAGES    (SYNC_STAGES)
    ) cpu_clk_sync_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (i_cpu_clk),

        .async          (cpu_clk_async)
    );

    dff_synchroniser #(
        .SYNC_STAGES    (SYNC_STAGES)
    ) cpu_wr_sync_inst (
        .clk            (clk),
        .srst           (srst),
        .sync           (i_cpu_wr),

        .async          (cpu_wr_async)
    );

    always @(posedge clk) begin
        // defaults
        i_cpu_clk_d1    <= i_cpu_clk;
        i_cpu_wr_d1     <= i_cpu_wr;

        if (srst == 1'b1) begin
            i_cpu_clk_d1 <= 1'b0;
            i_cpu_wr_d1  <= 1'b0;
        end
    end

    assign i_cpu_clk_rise = i_cpu_clk & ~i_cpu_clk_d1;
    assign i_cpu_clk_fall = ~i_cpu_clk & i_cpu_clk_d1;
    assign i_cpu_clk_edge = i_cpu_clk ^ i_cpu_clk_d1;

    assign i_cpu_wr_edge  = i_cpu_wr ^ i_cpu_wr_d1;



    // NOTE: burst
    // sequencer
    // --------------

    assign i_wr_transaction = i_cpu_wr;

    always @(posedge clk) begin
        if (m_valid == 1'b0) begin
            // NOTE: not currently transacting with downstream...

            // NOTE: Each beat corresponds to one of 4 burst stages.
            // the first 2 always receives an address (always read)
            // then the last are dependent on the wr signal for writing or reading
            // In that case the first 2 cases will (when used) always be true.
            if (i_cpu_clk_rise == 1'b1) begin
                i_transaction <= i_transaction + 1;

                case (i_transaction)
                    2'b00:                                      begin
                        m_wstrb         <= i_wr_transaction;
                        m_addr[15:0]    <= cpu_data_async;
                    end

                    2'b01:                                      begin
                        m_addr[31:16] <= cpu_data_async;

                        if (i_wr_transaction == 1'b0) begin
                            m_valid <= 1'b1;
                        end
                    end

                    2'b10:                                      begin
                        m_wdata[15:0] <= cpu_data_async;
                    end

                    default:                                    begin
                        m_wdata[31:16] <= cpu_data_async;

                        if (i_wr_transaction == 1'b1) begin
                            m_valid <= 1'b1;
                        end
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

                if (i_wr_transaction == 1'b0) begin
                    case (i_transaction)
                        2'b10:                                  begin
                            i_bus_out   <= m_rdata[15:0];
                            i_bus_drive <= 1'b1;
                        end

                        2'b11:                                  begin
                            i_bus_out   <= m_rdata[31:16];
                                // REVISIT: shift preferred as opposed to demux,
                                // i.e. 'i_bus_out' to be 32 bits, the lower 16
                                // of which are taped for cpu_data_async, and
                                // 'i_bus_out' is shifted right on this final
                                // transaction...

                            i_bus_drive <= 1'b1;
                        end

                        default: ;
                    endcase
                end
            end
        end
        else begin
            if (m_ready == 1'b1) begin
                // NOTE: handshake completes transaction
                // with downstream...

                m_valid <= 1'b0;
            end
        end

        if (i_cpu_wr_edge == 1'b1) begin
            // NOTE: we can safely reset the transaction
            // count on any edge of the 'cpu wr' strobe,
            // as it will always signal the beginning of
            // a transaction.

            i_transaction   <= 2'b00;
            i_bus_drive     <= 1'b0;
        end

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            m_valid             <= 1'b0;

            i_transaction       <= 2'b00;

            i_bus_drive         <= 1'b0;
        end
    end

endmodule
