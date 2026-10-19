// =============================================================================
// tflex_fault_injector -- applies fault_cmd_t commands to the lane data of one
// channel direction (Milestone 2 subset, plan.md decision 4).
//
// Supported modes (others are ignored and asserted against in M2):
//   FM_BIT_FLIP    one-shot: flips bit `bit_idx` of every lane in `lane_mask`
//                  on the first valid beat at or after `start_cycle`
//                  (one lane in the mask = single-bit corruption)
//   FM_CRC_CORRUPT one-shot: inverts the 16 CRC bits of the first valid,
//                  non-IDLE flit at or after `start_cycle`
//   FM_LANE_DEAD   selected lane failure: lanes in `lane_mask` carry noise
//                  bytes for cycles [start_cycle, start_cycle + duration),
//                  or permanently from start_cycle when duration = 0
// One-shot modes act on the first *valid* beat at or after start_cycle because
// a corrupted idle beat carries nothing; start_cycle <= cycle means "next beat".
//
// M2 assumes the full-width identity lane map (one beat = one flit, flit bits
// 15:0 = CRC on physical lanes 0-1, ftype on lane 31). Milestone 3/4 extend
// CRC_CORRUPT to the gearbox framing and add the remaining fault modes.
//
// `cycle` is a free-running link-clock counter (the time base of start_cycle).
// Loading FM_NONE into a slot clears it. Dead lanes are replaced first; bit
// flips and CRC inversions of all slots are then XORed on top.
// =============================================================================
module tflex_fault_injector
  import tflex_pkg::*;
#(
  parameter int  N_CMDS = 4,
  localparam int SW     = (N_CMDS > 1) ? $clog2(N_CMDS) : 1,
  localparam int DW     = PHYS_LANES * LANE_BITS
) (
  input  logic              clk,
  input  logic              rst_n,
  // command load
  input  logic              cmd_valid,
  input  logic [SW-1:0]     cmd_slot,
  input  fault_cmd_t        cmd,
  // lane data in / out (combinational)
  input  logic              in_valid,
  input  logic [DW-1:0]     in_data,
  output logic              out_valid,
  output logic [DW-1:0]     out_data,
  // status
  output logic [31:0]       cycle,
  output logic [N_CMDS-1:0] armed,           // one-shot command not yet applied
  output logic [31:0]       stat_corrupted   // valid beats whose lane data was changed
);
  fault_cmd_t        slot_q  [N_CMDS];
  logic [N_CMDS-1:0] armed_q, fire;
  logic [31:0]       cycle_q, noise_q;

  function automatic logic in_window(logic [31:0] start, logic [23:0] dur, logic [31:0] now);
    return (now >= start) && (dur == '0 || (now - start) < 32'(dur));
  endfunction

  // Per-cycle masks (constant indices only, so synthesis elaborates quickly):
  // dead lanes are replaced by noise first, then bit flips / CRC inversions are
  // XORed on top.
  logic [DW-1:0] dead_m, flip_m, noise;

  always_comb begin
    for (int l = 0; l < PHYS_LANES; l++)
      noise[l*LANE_BITS +: LANE_BITS] = LANE_BITS'(mix32(noise_q ^ {4{8'(l)}}));
  end

  always_comb begin
    dead_m = '0;
    flip_m = '0;
    fire   = '0;
    for (int i = 0; i < N_CMDS; i++) begin
      case (slot_q[i].mode)
        FM_BIT_FLIP:
          if (armed_q[i] && in_valid && cycle_q >= slot_q[i].start_cycle) begin
            fire[i] = 1'b1;
            for (int l = 0; l < PHYS_LANES; l++)
              for (int b = 0; b < LANE_BITS; b++)
                if (slot_q[i].lane_mask[l] && slot_q[i].bit_idx == 3'(b))
                  flip_m[l*LANE_BITS + b] = ~flip_m[l*LANE_BITS + b];
          end
        FM_CRC_CORRUPT:
          if (armed_q[i] && in_valid && cycle_q >= slot_q[i].start_cycle &&
              flit_type_e'(in_data[FLIT_BITS-1 -: 3]) != FT_IDLE) begin
            fire[i] = 1'b1;
            flip_m[CRC_BITS-1:0] = ~flip_m[CRC_BITS-1:0];
          end
        FM_LANE_DEAD:
          if (in_window(slot_q[i].start_cycle, slot_q[i].duration, cycle_q))
            for (int l = 0; l < PHYS_LANES; l++)
              if (slot_q[i].lane_mask[l]) dead_m[l*LANE_BITS +: LANE_BITS] = '1;
        default: ;
      endcase
    end
    out_data = ((in_data & ~dead_m) | (noise & dead_m)) ^ flip_m;
  end

  assign out_valid = in_valid;      // the valid lane is fault-free (limitations.md)
  assign cycle     = cycle_q;
  assign armed     = armed_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < N_CMDS; i++) slot_q[i] <= '0;
      armed_q        <= '0;
      cycle_q        <= '0;
      noise_q        <= 32'h1357_9BDF;          // xorshift32: any non-zero seed
      stat_corrupted <= '0;
    end else begin
      cycle_q        <= cycle_q + 32'd1;
      noise_q        <= mix32(noise_q);
      stat_corrupted <= sat_inc(stat_corrupted, in_valid && out_data != in_data);
      armed_q        <= armed_q & ~fire;
      if (cmd_valid) begin
        slot_q[cmd_slot]  <= cmd;
        armed_q[cmd_slot] <= (cmd.mode == FM_BIT_FLIP) || (cmd.mode == FM_CRC_CORRUPT);
      end
    end
  end
endmodule
