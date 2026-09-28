// =============================================================================
// tflex_phy_rx -- logical PHY receiver (Milestone 1: full width, identity map).
// Reassembles the flit from physical lanes 0..DATA_LANES-1; spares ignored.
// Milestone 3/4 add lane mapping, gearbox, deskew and training here.
// =============================================================================
module tflex_phy_rx
  import tflex_pkg::*;
(
  input  logic                             clk,
  input  logic                             rst_n,
  input  logic                             lane_valid,
  input  logic [PHYS_LANES*LANE_BITS-1:0]  lane_data,
  output logic                             out_valid,
  output flit_t                            out_flit
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_flit  <= '0;
    end else begin
      out_valid <= lane_valid;
      out_flit  <= flit_t'(lane_data[FLIT_BITS-1:0]);
    end
  end

  logic unused_spares;
  assign unused_spares = ^lane_data[PHYS_LANES*LANE_BITS-1:FLIT_BITS];
endmodule
