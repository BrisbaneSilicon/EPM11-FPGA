`timescale 1ns/1ps

module cpu_bus #(
    parameter int SYNC_STAGES = 2
) (
    // -------------- FPGA clocking --------------

    input   logic           clk,
    input   logic           srst,


    // -------------- Host wires --------------
    // NOTE: 'cpu_wr_async' frames each transaction,
    // high for all of it and low between them...

    inout   wire    [15:0]  cpu_data_async,
    input   logic           cpu_clk_async,
    input   logic           cpu_wr_async,


    // -------------- Host wires, synchronised --------------
    // NOTE: what this module acts on, for debug...

    output  logic   [15:0]  cpu_data_sync,
    output  logic           cpu_clk_sync,
    output  logic           cpu_wr_sync,


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
        // NOTE: 'm_ready' may take as long as it
        // needs, the RPI keeps polling for it...
);


    // ----------------------------------------------
    //  Protocol
    // ----------------------------------------------
    //
    //  'wr' is high for a whole transaction and low between them. Low
    //  always brings this module back to beat 0 with the lines released,
    //  so a bad transaction can never upset the next one.
    //
    //  The RPI drives one word per rising edge of its clock:
    //
    //      write:  CMD_WRITE  addr[15:0]  addr[31:16]  data[15:0]  data[31:16]  CHECK
    //      read:   CMD_READ   addr[15:0]  addr[31:16]  CHECK
    //
    //  CHECK is the CRC of the words before it. Only a frame with a good
    //  command and a good CHECK is acted on or answered. Anything else,
    //  including a frame with too many or too few beats, gets no answer.
    //
    //  The RPI then releases the lines and keeps clocking, and we drive one
    //  word per falling edge: BUSY until downstream has taken the request,
    //  then READY. A read carries on with data[15:0], data[31:16] and the
    //  CHECK of those two. ERROR means a good frame was refused, because an
    //  earlier request is still waiting on downstream.

    localparam logic [15:0] cCMD_WRITE      = 16'hA501;
    localparam logic [15:0] cCMD_READ       = 16'hA500;

    localparam logic [15:0] cSTATUS_BUSY    = 16'h5A00;
    localparam logic [15:0] cSTATUS_READY   = 16'h5A01;
    localparam logic [15:0] cSTATUS_ERROR   = 16'h5AEE;

    localparam logic [15:0] cCRC_INIT       = 16'hFFFF;


    // NOTE: CRC-16/CCITT, one 16-bit word at a time
    function automatic logic [15:0] crc16(input logic [15:0] crc, input logic [15:0] word);
        logic [15:0] c;

        c = crc ^ word;

        for (int i = 0; i < 16; i++) begin
            c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
        end

        return c;
    endfunction


    // ----------------------------------------------
    //  Internal signals
    // ----------------------------------------------

    logic           i_cpu_clk;
    logic           i_cpu_clk_d1;
    logic           i_cpu_clk_rise;
    logic           i_cpu_clk_fall;
    logic           i_cpu_clk_edge;

    logic           i_cpu_wr;
    logic           i_frame;

    logic   [SYNC_STAGES-1:0] [15:0]    i_cpu_data_pipe;
    logic   [15:0]  i_cpu_data;

    logic   [2:0]   i_transaction;
    logic           i_last_beat;
    logic           i_is_write;
    logic           i_cmd_ok;
    logic   [15:0]  i_crc;
    logic   [31:0]  i_req_addr;
    logic   [31:0]  i_req_wdata;

    logic           i_request_done;
    logic           i_answering;
    logic           i_refused;
    logic           i_requested;
    logic           i_ready;
    logic   [1:0]   i_words_out;
    logic   [31:0]  i_rdata;

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

        if (srst == 1'b1) begin
            i_cpu_clk_d1 <= 1'b0;
        end
    end

    // NOTE: one register per data pin, fed
    // straight from the pad so it can be placed
    // in the IOB, then synchronised as deep as
    // the clk and wr strobes...

    always @(posedge clk) begin
        i_cpu_data_pipe[0] <= cpu_data_async;

        for (int i = 1; i < SYNC_STAGES; i++) begin
            i_cpu_data_pipe[i] <= i_cpu_data_pipe[i-1];
        end
    end

    assign i_cpu_data     = i_cpu_data_pipe[SYNC_STAGES-1];

    assign cpu_data_sync  = i_cpu_data;
    assign cpu_clk_sync   = i_cpu_clk;
    assign cpu_wr_sync    = i_cpu_wr;

    assign i_cpu_clk_rise = i_cpu_clk & ~i_cpu_clk_d1;
    assign i_cpu_clk_fall = ~i_cpu_clk & i_cpu_clk_d1;
    assign i_cpu_clk_edge = i_cpu_clk ^ i_cpu_clk_d1;



    // NOTE: burst
    // sequencer
    // --------------

    assign i_frame     = i_cpu_wr;
    assign i_last_beat = (i_transaction == (i_is_write ? 3'd5 : 3'd3));

    always @(posedge clk) begin

        // NOTE: the request, one word per rising
        // edge of the RPI's clock...

        if (i_cpu_clk_rise == 1'b1 && i_request_done == 1'b0) begin
            i_transaction <= i_transaction + 1;
            i_crc         <= crc16(i_crc, i_cpu_data);

            case (i_transaction)
                3'd0:                                       begin
                    i_is_write          <= (i_cpu_data == cCMD_WRITE);
                    i_cmd_ok            <= (i_cpu_data == cCMD_WRITE) ||
                                           (i_cpu_data == cCMD_READ);
                end

                3'd1:   i_req_addr[15:0]    <= i_cpu_data;
                3'd2:   i_req_addr[31:16]   <= i_cpu_data;
                3'd3:   i_req_wdata[15:0]   <= i_cpu_data;
                3'd4:   i_req_wdata[31:16]  <= i_cpu_data;

                default: ;
            endcase

            if (i_last_beat == 1'b1) begin
                i_request_done <= 1'b1;

                if (i_cmd_ok == 1'b1 && i_cpu_data == i_crc) begin
                    i_answering <= 1'b1;

                    if (m_valid == 1'b0) begin
                        m_addr      <= i_req_addr;
                        m_wdata     <= i_req_wdata;
                        m_wstrb     <= i_is_write;
                        m_valid     <= 1'b1;
                        i_requested <= 1'b1;
                    end
                    else begin
                        i_refused   <= 1'b1;
                    end
                end
            end
        end

        // NOTE: the answer, one word per falling edge.
        // The RPI lets go of the lines before this edge,
        // so both sides never drive at once...

        if (i_cpu_clk_fall == 1'b1 && i_answering == 1'b1) begin
            i_bus_drive <= 1'b1;

            if (i_refused == 1'b1) begin
                i_bus_out <= cSTATUS_ERROR;
            end
            else if (i_ready == 1'b0) begin
                i_bus_out <= cSTATUS_BUSY;
            end
            else if (i_is_write == 1'b1) begin
                i_bus_out <= cSTATUS_READY;
            end
            else begin
                case (i_words_out)
                    2'd0:       i_bus_out <= cSTATUS_READY;
                    2'd1:       i_bus_out <= i_rdata[15:0];
                    2'd2:       i_bus_out <= i_rdata[31:16];
                    default:    i_bus_out <= crc16(crc16(cCRC_INIT, i_rdata[15:0]), i_rdata[31:16]);
                endcase

                if (i_words_out != 2'd3) begin
                    i_words_out <= i_words_out + 1;
                end
            end
        end

        // NOTE: the handshake with downstream. 'm_valid'
        // holds until 'm_ready', whatever the RPI does...

        if (m_valid == 1'b1 && m_ready == 1'b1) begin
            m_valid <= 1'b0;

            if (i_requested == 1'b1) begin
                i_ready <= 1'b1;
                i_rdata <= m_rdata;
            end
        end

        // NOTE: frame low, so back to beat 0 and off
        // the bus. A request already out on 'm_valid'
        // is left to finish...

        if (i_frame == 1'b0) begin
            i_transaction   <= 3'd0;
            i_crc           <= cCRC_INIT;
            i_cmd_ok        <= 1'b0;
            i_request_done  <= 1'b0;
            i_answering     <= 1'b0;
            i_refused       <= 1'b0;
            i_requested     <= 1'b0;
            i_ready         <= 1'b0;
            i_words_out     <= 2'd0;
            i_bus_drive     <= 1'b0;
        end

        // NOTE: handle reset here in order to
        // reduce control sets...
        if (srst == 1'b1) begin
            m_valid         <= 1'b0;

            i_transaction   <= 3'd0;
            i_request_done  <= 1'b0;
            i_answering     <= 1'b0;

            i_bus_drive     <= 1'b0;
        end
    end

endmodule
