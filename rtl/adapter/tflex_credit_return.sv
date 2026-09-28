// =============================================================================
// tflex_credit_return -- turns RX FIFO reads into credit-return messages.
//
// The RX FIFO's read pointer, synchronized into the link domain (w_rptr_bin),
// advances whenever the consumer frees a slot. Each cycle the number of slots
// freed since the last report is sent as one message (coalesced). Because the
// same synchronized pointer drives the FIFO's full flag, credits never exceed
// the space the FIFO itself believes it has.
// =============================================================================
module tflex_credit_return #(
  parameter int PTR_W = 7            // ADDR_W + 1 of the RX FIFO
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [PTR_W-1:0] rptr_bin,  // synchronized RX FIFO read pointer
  output logic             msg_valid,
  output logic [PTR_W-1:0] msg_count
);
  logic [PTR_W-1:0] last_q;
  logic [PTR_W-1:0] freed;

  assign freed = rptr_bin - last_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_q    <= '0;
      msg_valid <= 1'b0;
      msg_count <= '0;
    end else begin
      msg_valid <= (freed != '0);
      msg_count <= freed;
      last_q    <= rptr_bin;
    end
  end
endmodule
