// =============================================================================
// tflex_delay_line -- fixed-latency pipe of LATENCY register stages (>= 1).
// Used by the channel model (lane data) and the sideband channel (messages).
// The valid bit is reset; data registers are not (they are don't-care while
// invalid), which keeps wide pipes cheap.
// =============================================================================
module tflex_delay_line #(
  parameter int WIDTH   = 1,
  parameter int LATENCY = 1
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             in_valid,
  input  logic [WIDTH-1:0] in_data,
  output logic             out_valid,
  output logic [WIDTH-1:0] out_data
);
  logic             v_q [LATENCY];
  logic [WIDTH-1:0] d_q [LATENCY];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < LATENCY; i++) v_q[i] <= 1'b0;
    end else begin
      v_q[0] <= in_valid;
      for (int i = 1; i < LATENCY; i++) v_q[i] <= v_q[i-1];
    end
  end

  always_ff @(posedge clk) begin
    d_q[0] <= in_data;
    for (int i = 1; i < LATENCY; i++) d_q[i] <= d_q[i-1];
  end

  assign out_valid = v_q[LATENCY-1];
  assign out_data  = d_q[LATENCY-1];
endmodule
