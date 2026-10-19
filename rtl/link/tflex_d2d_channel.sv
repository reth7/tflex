// =============================================================================
// tflex_d2d_channel -- [sim] model of the die-to-die medium, one direction.
// Lane data passes the fault injector (Milestone 2 subset) and is then delayed
// by LATENCY link-clock cycles on every physical lane and the valid lane.
// Per-lane skew is added in Milestone 4. Synthesizable, but not part of any die.
// =============================================================================
module tflex_d2d_channel
  import tflex_pkg::*;
#(
  parameter int  LATENCY = 8,
  parameter int  FI_CMDS = 4,
  localparam int FI_SW   = (FI_CMDS > 1) ? $clog2(FI_CMDS) : 1
) (
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            tx_valid,
  input  logic [PHYS_LANES*LANE_BITS-1:0] tx_data,
  output logic                            rx_valid,
  output logic [PHYS_LANES*LANE_BITS-1:0] rx_data,
  // fault injection
  input  logic                            fi_cmd_valid,
  input  logic [FI_SW-1:0]                fi_cmd_slot,
  input  fault_cmd_t                      fi_cmd,
  output logic [31:0]                     fi_cycle,
  output logic [31:0]                     fi_corrupted
);
  logic                            inj_valid;
  logic [PHYS_LANES*LANE_BITS-1:0] inj_data;
  logic [FI_CMDS-1:0]              fi_armed;

  tflex_fault_injector #(.N_CMDS(FI_CMDS)) u_inj (
    .clk, .rst_n,
    .cmd_valid(fi_cmd_valid), .cmd_slot(fi_cmd_slot), .cmd(fi_cmd),
    .in_valid(tx_valid), .in_data(tx_data),
    .out_valid(inj_valid), .out_data(inj_data),
    .cycle(fi_cycle), .armed(fi_armed), .stat_corrupted(fi_corrupted)
  );

  tflex_delay_line #(.WIDTH(PHYS_LANES*LANE_BITS), .LATENCY(LATENCY)) u_dly (
    .clk, .rst_n,
    .in_valid (inj_valid), .in_data (inj_data),
    .out_valid(rx_valid),  .out_data(rx_data)
  );

  logic unused_armed;
  assign unused_armed = ^fi_armed;
endmodule
