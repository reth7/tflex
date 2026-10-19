// =============================================================================
// tflex_fault_injector checks (bound in simulation).
//  - only the Milestone 2 subset of fault modes is ever loaded
//  - the valid lane passes through unchanged (assumed fault-free)
//  - one-shot commands act only on valid beats and only once per load
// =============================================================================
module tflex_fault_injector_sva
  import tflex_pkg::*;
#(
  parameter int N_CMDS = 4
) (
  input logic              clk, rst_n,
  input logic              cmd_valid,
  input fault_cmd_t        cmd,
  input logic              in_valid, out_valid,
  input logic [N_CMDS-1:0] fire, armed_q
);
  a_m2_modes: assert property (@(posedge clk) disable iff (!rst_n)
      cmd_valid |-> cmd.mode inside {FM_NONE, FM_BIT_FLIP, FM_CRC_CORRUPT, FM_LANE_DEAD})
    else $error("fault_injector: mode %0d is not implemented in Milestone 2", cmd.mode);
  a_valid_lane: assert property (@(posedge clk) disable iff (!rst_n) out_valid == in_valid)
    else $error("fault_injector: valid lane modified");
  a_fire_valid: assert property (@(posedge clk) disable iff (!rst_n) (fire != '0) |-> in_valid)
    else $error("fault_injector: one-shot fault applied to an idle beat");
  a_fire_armed: assert property (@(posedge clk) disable iff (!rst_n) (fire & ~armed_q) == '0)
    else $error("fault_injector: one-shot fault applied twice");
endmodule

bind tflex_fault_injector tflex_fault_injector_sva #(.N_CMDS(N_CMDS)) u_fi_sva (
  .clk, .rst_n, .cmd_valid, .cmd, .in_valid, .out_valid, .fire, .armed_q
);
