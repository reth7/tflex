// =============================================================================
// tb_fault_injector -- directed + seeded-random test of tflex_fault_injector.
//
// Random lane data and valid pattern every cycle; commands loaded at chosen
// cycles. An independent model in this testbench predicts, per cycle, which
// bits each command changes; the checker requires that
//   - bits outside dead lanes differ from the input exactly by the predicted
//     bit-flip / CRC-inversion mask,
//   - dead lanes are replaced only inside [start, start + duration),
//   - one-shot commands fire exactly once, on the first valid (non-IDLE for
//     CRC_CORRUPT) beat at or after start_cycle,
//   - stat_corrupted equals the number of valid beats whose data changed,
//   - the cycle counter advances by one per clock from reset.
// Plusargs: +NCYC=<cycles of the random phase>; seeded with +verilator+seed+<n>.
// =============================================================================
module tb_fault_injector;
  import tflex_pkg::*;
  localparam int N  = 4;
  localparam int DW = PHYS_LANES * LANE_BITS;

  logic clk = 1'b0, arst_n = 1'b1, rst_n;
  always #500 clk = ~clk;
  initial begin #1 arst_n = 1'b0; #5000 arst_n = 1'b1; end   // real reset edge, then release
  tflex_reset_sync u_rs (.clk, .arst_n, .rst_n_o(rst_n));

  logic          cmd_valid = 1'b0, in_valid = 1'b0;
  logic [1:0]    cmd_slot = '0;
  fault_cmd_t    cmd = '0;
  logic [DW-1:0] in_data = '0, out_data;
  logic          out_valid;
  logic [31:0]   cycle, stat_corrupted;
  logic [N-1:0]  armed;

  tflex_fault_injector #(.N_CMDS(N)) dut (
    .clk, .rst_n, .cmd_valid, .cmd_slot, .cmd, .in_valid, .in_data,
    .out_valid, .out_data, .cycle, .armed, .stat_corrupted
  );

  // ------------------------------------------------------------ model
  fault_cmd_t  m_cmd   [N];
  bit          m_armed [N];
  int unsigned errors = 0, fired_cnt [N], dead_hits = 0, dead_cycles = 0, corrupted_exp = 0;
  int unsigned idle_pct = 30;   // % of valid beats that carry an IDLE flit
  logic [31:0] tb_cycle = 0;

  // Drive inputs on the falling edge; check and update the model on the rising
  // edge (the DUT's combinational output is stable then, before its registers update).
  task automatic drive_random(int unsigned valid_pct);
    logic [DW-1:0] d;
    for (int w = 0; w < DW / 32; w++) d[w*32 +: 32] = $urandom;
    in_valid = ($urandom % 100) < valid_pct;
    if (($urandom % 100) < idle_pct) d[FLIT_BITS-1 -: 3] = FT_IDLE;
    else                             d[FLIT_BITS-1 -: 3] = 3'(1 + $urandom % 4);
    in_data = d;
  endtask

  always @(posedge clk) begin
    if (rst_n) begin
      logic [DW-1:0] flip, dead, diff;
      bit            fire [N];
      flip = '0; dead = '0;
      if (cycle != tb_cycle) begin $error("cycle counter %0d, expected %0d", cycle, tb_cycle); errors++; end
      for (int i = 0; i < N; i++) begin
        fire[i] = 0;
        case (m_cmd[i].mode)
          FM_BIT_FLIP:
            if (m_armed[i] && in_valid && tb_cycle >= m_cmd[i].start_cycle) begin
              fire[i] = 1;
              for (int l = 0; l < PHYS_LANES; l++)
                if (m_cmd[i].lane_mask[l]) flip[l*8 + int'(m_cmd[i].bit_idx)] ^= 1'b1;
            end
          FM_CRC_CORRUPT:
            if (m_armed[i] && in_valid && tb_cycle >= m_cmd[i].start_cycle &&
                in_data[FLIT_BITS-1 -: 3] != FT_IDLE) begin
              fire[i] = 1;
              flip[15:0] ^= 16'hFFFF;
            end
          FM_LANE_DEAD:
            if (tb_cycle >= m_cmd[i].start_cycle &&
                (m_cmd[i].duration == 0 || tb_cycle - m_cmd[i].start_cycle < 32'(m_cmd[i].duration))) begin
              for (int l = 0; l < PHYS_LANES; l++)
                if (m_cmd[i].lane_mask[l]) dead[l*8 +: 8] = 8'hFF;
            end
          default: ;
        endcase
      end
      diff = out_data ^ in_data;
      // flips act on top of dead-lane noise, so they are checked outside dead lanes only
      if ((diff & ~dead) != (flip & ~dead)) begin
        $error("cycle %0d: unexpected change outside dead lanes: diff %h expected %h", tb_cycle, diff & ~dead, flip & ~dead);
        errors++;
      end
      if (dead != '0) begin
        dead_cycles++;
        if ((diff & dead) != '0) dead_hits++;
      end
      if (out_valid != in_valid) begin $error("valid lane changed"); errors++; end
      if (in_valid && diff != '0) corrupted_exp++;
      for (int i = 0; i < N; i++) if (fire[i]) begin m_armed[i] = 0; fired_cnt[i]++; end
      if (cmd_valid) begin
        m_cmd[cmd_slot]   = cmd;
        m_armed[cmd_slot] = (cmd.mode == FM_BIT_FLIP) || (cmd.mode == FM_CRC_CORRUPT);
        fired_cnt[cmd_slot] = 0;
      end
      tb_cycle++;
    end
  end

  task automatic load(int slot, fault_mode_e mode, logic [PHYS_LANES-1:0] mask, int unsigned bit_idx,
                      logic [31:0] start, logic [23:0] dur);
    @(negedge clk);
    // whole-struct assignment (testbench rule, verification.md section 5)
    cmd = '{mode: mode, lane_mask: mask, bit_idx: 3'(bit_idx), start_cycle: start, duration: dur, ber_thresh: '0};
    cmd_slot = 2'(slot); cmd_valid = 1'b1;
    drive_random(50);
    @(negedge clk);
    cmd_valid = 1'b0;
  endtask

  task automatic run(int unsigned ncyc, int unsigned valid_pct);
    repeat (ncyc) begin @(negedge clk); drive_random(valid_pct); end
  endtask

  task automatic expect_fired(int slot, int unsigned n, string what);
    if (fired_cnt[slot] != n) begin $error("%s: fired %0d times, expected %0d", what, fired_cnt[slot], n); errors++; end
  endtask

  int unsigned ncyc = 20000;
  initial begin
    void'($value$plusargs("NCYC=%d", ncyc));
    for (int i = 0; i < N; i++) begin m_cmd[i] = '0; m_armed[i] = 0; fired_cnt[i] = 0; end
    wait (rst_n);
    // 1. no command: transparent
    run(200, 60);
    // 2. single-bit flip with start in the future, sparse valid beats
    load(0, FM_BIT_FLIP, 36'(1) << 5, 3, tb_cycle + 20, 0);
    run(100, 20);
    expect_fired(0, 1, "bit flip");
    // 3. CRC corrupt must skip IDLE flits
    idle_pct = 70;
    load(1, FM_CRC_CORRUPT, '0, 0, tb_cycle + 10, 0);
    run(100, 60);
    idle_pct = 30;
    expect_fired(1, 1, "crc corrupt");
    // 4. dead lanes 7 and 33 for 50 cycles, then a permanent dead lane 0 cleared by FM_NONE
    load(2, FM_LANE_DEAD, (36'(1) << 7) | (36'(1) << 33), 0, tb_cycle + 5, 24'd50);
    run(100, 60);
    load(3, FM_LANE_DEAD, 36'(1), 0, tb_cycle + 3, 0);
    run(300, 60);
    load(3, FM_NONE, '0, 0, 0, 0);
    run(50, 60);
    // 5. start already in the past: next valid beat
    load(0, FM_BIT_FLIP, (36'(1) << 31) | (36'(1) << 2), 7, 0, 0);
    run(20, 60);
    expect_fired(0, 1, "bit flip (past start)");
    // 6. random phase: random commands in random slots
    for (int k = 0; k < int'(ncyc) / 100; k++) begin
      int unsigned m;
      m = $urandom % 4;
      load($urandom % N, (m == 0) ? FM_BIT_FLIP : (m == 1) ? FM_CRC_CORRUPT : (m == 2) ? FM_LANE_DEAD : FM_NONE,
           {$urandom, $urandom} & ((36'(1) << ($urandom % 36)) | (($urandom % 4 == 0) ? (36'(1) << ($urandom % 36)) : '0)),
           $urandom % 8, tb_cycle + ($urandom % 40), 24'($urandom % 60));
      run(98, 1 + $urandom % 100);
    end
    @(negedge clk);
    if (stat_corrupted != corrupted_exp) begin
      $error("stat_corrupted %0d, model %0d", stat_corrupted, corrupted_exp); errors++;
    end
    // dead lanes replaced by noise: a noise byte equals the data byte with p = 1/256
    if (dead_cycles == 0 || dead_hits * 100 < dead_cycles * 90) begin
      $error("dead lanes changed on only %0d of %0d cycles", dead_hits, dead_cycles); errors++;
    end
    $display("RESULT tb=fault_injector cycles=%0d corrupted_beats=%0d dead_cycles=%0d dead_changed=%0d errors=%0d %s",
             tb_cycle, stat_corrupted, dead_cycles, dead_hits, errors, (errors == 0) ? "PASS" : "FAIL");
    if (errors != 0) $fatal(1, "tb_fault_injector FAILED");
    $finish;
  end
endmodule
