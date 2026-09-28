// =============================================================================
// tflex_phy_tx -- logical PHY transmitter (Milestone 1: full width, identity map).
//
// Stripes a 256-bit flit onto DATA_LANES logical lanes of LANE_BITS bits:
// logical lane k carries flit byte k (bits [8k+7:8k]). Logical lane k drives
// physical lane k; the SPARE_LANES spare physical lanes are driven to zero.
// A dedicated valid lane (assumed fault-free) marks beats carrying a flit.
// Milestone 3 inserts the gearbox (32/16/8 widths) and the lane mapper here.
// =============================================================================
module tflex_phy_tx
  import tflex_pkg::*;
(
  input  logic                             clk,
  input  logic                             rst_n,
  input  logic                             in_valid,
  input  flit_t                            in_flit,
  output logic                             lane_valid,
  output logic [PHYS_LANES*LANE_BITS-1:0]  lane_data
);
  logic [FLIT_BITS-1:0] flit_bits;
  assign flit_bits = in_flit;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lane_valid <= 1'b0;
      lane_data  <= '0;
    end else begin
      lane_valid <= in_valid;
      lane_data  <= {{(SPARE_LANES*LANE_BITS){1'b0}}, flit_bits};
    end
  end
endmodule
