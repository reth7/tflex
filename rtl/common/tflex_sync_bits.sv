// =============================================================================
// tflex_sync_bits -- multi-flop synchronizer for a vector whose value changes
// by at most one bit per source-clock update (Gray-coded pointers) or that is
// quasi-static. It is NOT safe for arbitrary multi-bit buses.
// =============================================================================
module tflex_sync_bits #(
  parameter int WIDTH  = 1,
  parameter int STAGES = 2
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [WIDTH-1:0] d,
  output logic [WIDTH-1:0] q
);
  logic [WIDTH-1:0] stage_q [STAGES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < STAGES; i++) stage_q[i] <= '0;
    end else begin
      stage_q[0] <= d;
      for (int i = 1; i < STAGES; i++) stage_q[i] <= stage_q[i-1];
    end
  end

  assign q = stage_q[STAGES-1];
endmodule
