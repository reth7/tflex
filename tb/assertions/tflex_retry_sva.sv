// =============================================================================
// Milestone 2 link-layer checks (bound in simulation; verification.md section 4).
// The credit checks of the Milestone 1 adapter (credit maximum, no flit sent
// without a credit, no RX FIFO overflow) are carried over here.
// =============================================================================
module tflex_retry_tx_sva
  import tflex_pkg::*;
#(
  parameter int RETRY_DEPTH = 64,
  parameter int CREDITS     = 64,
  parameter int CW          = 7
) (
  input logic                clk, rst_n,
  input logic [CW-1:0]       credits_q,
  input logic                send_new, send_replay, out_valid, nak_ok, is_ack, is_nak,
  input logic [SEQ_BITS-1:0] outstanding, send_ptr, oldest, next_seq, adv_ack, adv_nak, sb_seq
);
  a_credit_max: assert property (@(posedge clk) disable iff (!rst_n) credits_q <= CW'(CREDITS))
    else $error("retry_tx: credits %0d exceed receiver buffer %0d (or went below zero)", credits_q, CREDITS);
  a_credit_send: assert property (@(posedge clk) disable iff (!rst_n) send_new |-> credits_q != '0)
    else $error("retry_tx: new flit sent without a credit");
  a_window: assert property (@(posedge clk) disable iff (!rst_n) outstanding <= SEQ_BITS'(RETRY_DEPTH))
    else $error("retry_tx: %0d flits outstanding, window is %0d", outstanding, RETRY_DEPTH);
  a_ack_sent: assert property (@(posedge clk) disable iff (!rst_n) is_ack |-> adv_ack <= outstanding)
    else $error("retry_tx: ACK(%0d) acknowledges an unsent flit (oldest %0d, next %0d)", sb_seq, oldest, next_seq);
  a_nak_sent: assert property (@(posedge clk) disable iff (!rst_n) is_nak |-> adv_nak <= outstanding)
    else $error("retry_tx: NAK(%0d) outside the window (oldest %0d, next %0d)", sb_seq, oldest, next_seq);
  a_replay_start: assert property (@(posedge clk) disable iff (!rst_n) nak_ok |=> send_ptr == $past(sb_seq))
    else $error("retry_tx: replay does not start at the NAKed sequence");
  a_replay_range: assert property (@(posedge clk) disable iff (!rst_n)
                                   send_replay |-> SEQ_BITS'(send_ptr - oldest) < outstanding)
    else $error("retry_tx: replaying sequence %0d outside the window", send_ptr);
  a_new_in_order: assert property (@(posedge clk) disable iff (!rst_n) send_new |-> send_ptr == next_seq)
    else $error("retry_tx: new flit sent while a replay is pending");
  logic in_rst_q = 1'b0;   // reset held for at least one clock
  always @(posedge clk) in_rst_q <= !rst_n;
  a_rst: assert property (@(posedge clk) (!rst_n && in_rst_q) |-> (!out_valid && credits_q == CW'(CREDITS)))
    else $error("retry_tx: not in reset state during reset");
endmodule

module tflex_retry_rx_sva
  import tflex_pkg::*;
(
  input logic                clk, rst_n, deliver, fifo_ready, crc_ok,
  input logic [SEQ_BITS-1:0] seq
);
  a_no_overflow: assert property (@(posedge clk) disable iff (!rst_n) deliver |-> fifo_ready)
    else $error("retry_rx: flit delivered with RX FIFO full (credit protocol violated)");
  a_deliver_crc: assert property (@(posedge clk) disable iff (!rst_n) deliver |-> crc_ok)
    else $error("retry_rx: delivered a flit with a bad CRC");
  // independent shadow of the expected sequence: deliveries increment by exactly one
  logic [SEQ_BITS-1:0] shadow_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)       shadow_q <= '0;
    else if (deliver) shadow_q <= shadow_q + 1'b1;
  a_deliver_order: assert property (@(posedge clk) disable iff (!rst_n) deliver |-> seq == shadow_q)
    else $error("retry_rx: delivered sequence %0d, expected %0d", seq, shadow_q);
endmodule

module tflex_credit_return_sva
  import tflex_pkg::*;
(
  input logic    clk, rst_n, msg_valid,
  input sb_msg_t msg
);
  a_credit_msg: assert property (@(posedge clk) disable iff (!rst_n)
                                 msg_valid |-> (msg.op == SB_CREDIT && msg.arg != '0 && msg.arg <= 40'd255))
    else $error("credit_return: malformed credit message");
endmodule

module tflex_sb_mux_sva
  import tflex_pkg::*;
#(
  parameter int N = 3
) (
  input logic [N-1:0] req_valid, req_ready,
  input logic         out_valid
);
  always_comb begin
    if (out_valid != (req_valid != '0)) $error("sb_mux: out_valid does not match requests");
    if ((req_ready & ~req_valid) != '0)  $error("sb_mux: grant without a request");
    if (req_valid != '0 && req_ready != (req_valid & (~req_valid + 1'b1)))
      $error("sb_mux: grant is not the highest-priority request");
  end
endmodule

bind tflex_retry_tx tflex_retry_tx_sva #(.RETRY_DEPTH(RETRY_DEPTH), .CREDITS(CREDITS), .CW(CW)) u_rtx_sva (
  .clk, .rst_n, .credits_q, .send_new, .send_replay, .out_valid, .nak_ok, .is_ack, .is_nak,
  .outstanding, .send_ptr, .oldest, .next_seq, .adv_ack, .adv_nak, .sb_seq
);
bind tflex_retry_tx tflex_stream_sva #(.WIDTH($bits(tflex_pkg::flit_t)), .NAME("retry_tx_out")) u_rtx_out_sva (
  .clk, .rst_n, .valid(out_valid), .ready(out_ready), .data(out_flit)
);
bind tflex_retry_rx tflex_retry_rx_sva u_rrx_sva (
  .clk, .rst_n, .deliver, .fifo_ready, .crc_ok, .seq(in_flit.seq)
);
bind tflex_retry_rx tflex_stream_sva #(.WIDTH($bits(tflex_pkg::sb_msg_t)), .NAME("ack_req")) u_ack_sva (
  .clk, .rst_n, .valid(ack_valid), .ready(ack_ready), .data(ack_msg)
);
bind tflex_retry_rx tflex_stream_sva #(.WIDTH($bits(tflex_pkg::sb_msg_t)), .NAME("nak_req")) u_nak_sva (
  .clk, .rst_n, .valid(nak_valid), .ready(nak_ready), .data(nak_msg)
);
bind tflex_credit_return tflex_credit_return_sva u_crr_sva (.clk, .rst_n, .msg_valid, .msg);
bind tflex_credit_return tflex_stream_sva #(.WIDTH($bits(tflex_pkg::sb_msg_t)), .NAME("credit_req")) u_crr_stream_sva (
  .clk, .rst_n, .valid(msg_valid), .ready(msg_ready), .data(msg)
);
bind tflex_sb_mux tflex_sb_mux_sva #(.N(N)) u_sbm_sva (.req_valid, .req_ready, .out_valid);
