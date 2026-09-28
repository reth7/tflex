// =============================================================================
// tflex_d2d_channel -- [sim] model of the die-to-die medium, one direction.
// Milestone 1: every physical lane and the valid lane are delayed by LATENCY
// link-clock cycles. Per-lane skew (M4) and the fault injector (M2/M4) are
// added here later. Synthesizable, but not part of any die.
// =============================================================================
module tflex_d2d_channel
  import tflex_pkg::*;
#(
  parameter int LATENCY = 8
) (
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            tx_valid,
  input  logic [PHYS_LANES*LANE_BITS-1:0] tx_data,
  output logic                            rx_valid,
  output logic [PHYS_LANES*LANE_BITS-1:0] rx_data
);
  tflex_delay_line #(.WIDTH(PHYS_LANES*LANE_BITS), .LATENCY(LATENCY)) u_dly (
    .clk, .rst_n,
    .in_valid (tx_valid), .in_data (tx_data),
    .out_valid(rx_valid), .out_data(rx_data)
  );
endmodule
