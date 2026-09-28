// =============================================================================
// tflex_adapter_rx -- link-layer receiver (Milestone 1 scope).
//
// Writes every received flit body into the RX async FIFO. The RX side never
// back-pressures the link: credit flow control guarantees space. A flit that
// arrives while the FIFO is full is a protocol violation, reported on
// overflow_err (and asserted against in tb/assertions).
// Milestone 2 adds CRC check, sequence tracking and ACK/NAK generation here.
// =============================================================================
module tflex_adapter_rx
  import tflex_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  flit_t       in_flit,
  // to RX FIFO (write side)
  output logic        fifo_valid,
  input  logic        fifo_ready,
  output flit_body_t  fifo_fb,
  // status / statistics
  output logic        overflow_err,
  output logic [31:0] stat_flits_rcvd
);
  assign fifo_valid   = in_valid;
  assign fifo_fb      = '{ftype: in_flit.ftype, body: in_flit.body};
  assign overflow_err = in_valid && !fifo_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                   stat_flits_rcvd <= '0;
    else if (in_valid && stat_flits_rcvd != '1)   stat_flits_rcvd <= stat_flits_rcvd + 1;
  end

  // Only seq/flags/crc are unused in M1 (consumed from Milestone 2 on).
  logic unused_ok;
  assign unused_ok = ^{in_flit.seq, in_flit.flags, in_flit.crc};
endmodule
