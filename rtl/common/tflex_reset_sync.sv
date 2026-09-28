// =============================================================================
// tflex_reset_sync -- asynchronous assert, synchronous deassert reset.
// One instance per clock domain. rst_n_o goes low immediately when arst_n goes
// low and returns high STAGES clock edges after arst_n is released.
// =============================================================================
module tflex_reset_sync #(
  parameter int STAGES = 2
) (
  input  logic clk,
  input  logic arst_n,
  output logic rst_n_o
);
  logic [STAGES-1:0] sync_q;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) sync_q <= '0;
    else         sync_q <= {sync_q[STAGES-2:0], 1'b1};
  end

  assign rst_n_o = sync_q[STAGES-1];
endmodule
