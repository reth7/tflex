// =============================================================================
// tflex_sideband_channel -- [sim] reliable fixed-latency message pipe, one
// direction. Milestone 1 carries credit-return counts; from Milestone 2 it
// carries sb_msg_t (ACK/NAK, credits, training messages).
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
