// =============================================================================
// tflex_adapter_tx -- link-layer transmitter (Milestone 1 scope).
//
// Pops flit bodies from the TX async FIFO when the receiver has buffer space
// (credit-based flow control) and emits one 256-bit flit per cycle towards the
// PHY. One credit = one flit slot in the receiver's RX FIFO; credits come back
// as counts over the sideband (tflex_credit_return at the far end).
//
// Milestone 2 adds sequence numbers, CRC and the go-back-N replay buffer here;
// in Milestone 1 seq/flags/crc are transmitted as zero.
// =============================================================================
module tflex_adapter_tx
  import tflex_pkg::*;
#(
  parameter int CREDITS = 64,               // = receiver RX FIFO depth
  localparam int CW     = $clog2(CREDITS + 1)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          enable,           // link up; M1: tied high after reset
  // from TX FIFO (read side)
  input  logic          in_valid,
  output logic          in_ready,
  input  flit_body_t    in_fb,
  // credit return from the far end
  input  logic          cr_valid,
  input  logic [CW-1:0] cr_count,
  // to PHY
  output logic          out_valid,
  output flit_t         out_flit,
  // status / statistics
  output logic [CW-1:0] credits,
  output logic [31:0]   stat_flits_sent,
  output logic [31:0]   stat_stall_no_credit
);
  logic [CW-1:0] credits_q;
  logic          send;
  logic [CW-1:0] cr_add;

  assign send     = enable && in_valid && (credits_q != '0);
  assign in_ready = enable && (credits_q != '0);
  assign cr_add   = cr_valid ? cr_count : '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      credits_q            <= CW'(CREDITS);
      out_valid            <= 1'b0;
      out_flit             <= '0;
      stat_flits_sent      <= '0;
      stat_stall_no_credit <= '0;
    end else begin
      credits_q <= credits_q + cr_add - CW'(send);
      out_valid <= send;
      if (send) begin
        out_flit <= '{ftype: in_fb.ftype, seq: '0, flags: '0, body: in_fb.body, crc: '0};
        if (stat_flits_sent != '1) stat_flits_sent <= stat_flits_sent + 1;
      end
      if (enable && in_valid && credits_q == '0 && stat_stall_no_credit != '1)
        stat_stall_no_credit <= stat_stall_no_credit + 1;
    end
  end

  assign credits = credits_q;
endmodule
