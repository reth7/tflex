// =============================================================================
// tflex_stream_sva -- valid/ready stream rules, bound onto stream interfaces.
//  - once valid is asserted it stays asserted until the transfer (valid && ready)
//  - data is held stable while valid && !ready
//  - valid is low while in reset (checked from the second clock of a reset,
//    because state at the very first edge after time zero is undefined)
// =============================================================================
module tflex_stream_sva #(
  parameter int    WIDTH = 1,
  parameter string NAME  = "stream"
) (
  input logic             clk,
  input logic             rst_n,
  input logic             valid,
  input logic             ready,
  input logic [WIDTH-1:0] data
);
  a_hold: assert property (@(posedge clk) disable iff (!rst_n)
                           (valid && !ready) |=> valid)
    else $error("[%s] valid dropped before transfer", NAME);

  a_stable: assert property (@(posedge clk) disable iff (!rst_n)
                             (valid && !ready) |=> $stable(data))
    else $error("[%s] data changed while stalled", NAME);

  logic in_rst_q = 1'b0;   // reset has been held for at least one clock
  always @(posedge clk) in_rst_q <= !rst_n;

  a_reset: assert property (@(posedge clk) (!rst_n && in_rst_q) |-> !valid)
    else $error("[%s] valid asserted during reset", NAME);
endmodule
