module sync_edge (
    input  logic clk,
    input  logic rst_n,
    input  logic async_in,
    output logic sync_out,
    output logic rise,       // one clk pulse on the rising edge
    output logic fall,       // one clk pulse on the falling edge
    output logic edge_any    // one clk pulse on either edge
);

    logic sync_d;

    // Reuse the existing synchroniser, this only adds the edge detect
    dff_sync sync_inst(.clk(clk), .rst_n(rst_n), .async_in(async_in), .sync_out(sync_out));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sync_d <= 1'b0;
        else
            sync_d <= sync_out;
    end

    assign rise     = sync_out & ~sync_d;
    assign fall     = ~sync_out & sync_d;
    assign edge_any = sync_out ^ sync_d;

endmodule
