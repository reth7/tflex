// =============================================================================
// Milestone 1 link-layer checks (bound in simulation).
// =============================================================================
module tflex_adapter_tx_sva #(
  parameter int CREDITS = 64,
  parameter int CW      = 7
) (
  input logic          clk, rst_n,
  input logic [CW-1:0] credits_q,
  input logic          send, out_valid, in_valid, in_ready
);
  a_credit_max: assert property (@(posedge clk) disable iff (!rst_n) credits_q <= CW'(CREDITS))
    else $error("adapter_tx: credits %0d exceed receiver buffer %0d", credits_q, CREDITS);
  a_credit_send: assert property (@(posedge clk) disable iff (!rst_n) send |-> credits_q != '0)
    else $error("adapter_tx: flit sent without a credit");
  logic in_rst_q = 1'b0;   // reset held for at least one clock
  always @(posedge clk) in_rst_q <= !rst_n;
  a_rst: assert property (@(posedge clk) (!rst_n && in_rst_q) |-> (!out_valid && credits_q == CW'(CREDITS)))
    else $error("adapter_tx: not in reset state during reset");
endmodule

module tflex_adapter_rx_sva (
  input logic clk, rst_n, in_valid, fifo_ready
);
  a_no_overflow: assert property (@(posedge clk) disable iff (!rst_n) in_valid |-> fifo_ready)
    else $error("adapter_rx: flit arrived with RX FIFO full (credit protocol violated)");
endmodule

bind tflex_adapter_tx tflex_adapter_tx_sva #(.CREDITS(CREDITS), .CW(CW)) u_atx_sva (
  .clk, .rst_n, .credits_q, .send, .out_valid, .in_valid, .in_ready
);

bind tflex_adapter_rx tflex_adapter_rx_sva u_arx_sva (
  .clk, .rst_n, .in_valid, .fifo_ready
);

bind tflex_traffic_src tflex_stream_sva #(.WIDTH($bits(tflex_pkg::pkt_item_t)), .NAME("src_out")) u_src_sva (
  .clk, .rst_n, .valid(out_valid), .ready(out_ready), .data(out_item)
);

bind tflex_depacketizer tflex_stream_sva #(.WIDTH($bits(tflex_pkg::pkt_item_t)), .NAME("depkt_out")) u_depkt_sva (
  .clk, .rst_n, .valid(out_valid), .ready(out_ready), .data(out_item)
);
