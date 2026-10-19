// =============================================================================
// Milestone 1 packet-stream checks (bound in simulation). The Milestone 1
// adapter credit checks moved to tflex_retry_sva.sv with the retry engines.
// =============================================================================
bind tflex_traffic_src tflex_stream_sva #(.WIDTH($bits(tflex_pkg::pkt_item_t)), .NAME("src_out")) u_src_sva (
  .clk, .rst_n, .valid(out_valid), .ready(out_ready), .data(out_item)
);

bind tflex_depacketizer tflex_stream_sva #(.WIDTH($bits(tflex_pkg::pkt_item_t)), .NAME("depkt_out")) u_depkt_sva (
  .clk, .rst_n, .valid(out_valid), .ready(out_ready), .data(out_item)
);
