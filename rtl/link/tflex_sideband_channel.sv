// =============================================================================
// tflex_sideband_channel -- [sim] reliable fixed-latency message pipe, one
// direction, one message per cycle. Carries sb_msg_t (WIDTH = $bits(sb_msg_t)):
// ACK / NAK / CREDIT from Milestone 2, training messages from Milestone 4.
// =============================================================================
module tflex_sideband_channel #(
  parameter int WIDTH   = 8,
  parameter int LATENCY = 8
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             tx_valid,
  input  logic [WIDTH-1:0] tx_msg,
  output logic             rx_valid,
  output logic [WIDTH-1:0] rx_msg
);
  tflex_delay_line #(.WIDTH(WIDTH), .LATENCY(LATENCY)) u_dly (
    .clk, .rst_n,
    .in_valid (tx_valid), .in_data (tx_msg),
    .out_valid(rx_valid), .out_data(rx_msg)
  );
endmodule
