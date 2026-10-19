// =============================================================================
// tflex_credit_return -- turns RX FIFO reads into SB_CREDIT messages.
//
// The RX FIFO's read pointer, synchronized into the link domain (w_rptr_bin),
// advances whenever the consumer frees a slot. Slots freed since the last
// report are sent as one SB_CREDIT(n) message (coalesced, n <= 255). The
// message is a valid/ready request to the sideband mux and is held until
// granted; slots freed meanwhile go into the next message. Because the same
// synchronized pointer drives the FIFO's full flag, credits never exceed the
// space the FIFO itself believes it has.
// =============================================================================
module tflex_credit_return
  import tflex_pkg::*;
#(
  parameter int PTR_W = 7            // ADDR_W + 1 of the RX FIFO
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [PTR_W-1:0] rptr_bin,  // synchronized RX FIFO read pointer
  output logic             msg_valid,
  input  logic             msg_ready,
  output sb_msg_t          msg
);
  localparam int MAXN = 255;          // 8-bit count field (protocol.md section 6)

  logic [PTR_W-1:0] last_q, freed, n;

  assign freed = rptr_bin - last_q;
  assign n     = (32'(freed) > MAXN) ? PTR_W'(MAXN) : freed;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_q    <= '0;
      msg_valid <= 1'b0;
      msg       <= '0;
    end else if (!msg_valid || msg_ready) begin
      msg_valid <= (freed != '0);
      if (freed != '0) begin
        msg    <= sb_make(SB_CREDIT, 40'(n));
        last_q <= last_q + n;
      end
    end
  end
endmodule
