// =============================================================================
// tb_async_fifo -- directed + seeded-random tests for tflex_async_fifo.
//
// Plusargs: +WCLK_PS=<period> +RCLK_PS=<period> +RPHASE_PS=<offset> +CFG=<name>
// Tests (run in sequence in one simulation):
//   T1 empty after reset      T2 fill to full        T3 drain in order
//   T4 simultaneous r/w       T5 random backpressure T6 reset mid-traffic
// Every accepted word is checked in order against a scoreboard queue.
// The bound SVA (tb/assertions) checks overflow/underflow, Gray pointers,
// stream stability and reset state throughout.
// =============================================================================
module tb_async_fifo;
  localparam int DEPTH  = 16;
  localparam int WIDTH  = 32;
  localparam int ADDR_W = $clog2(DEPTH);

  // ------------------------------------------------------------ clocks/resets
  int unsigned wclk_ps = 1000, rclk_ps = 1000, rphase_ps = 0;
  string       cfg = "default";
  logic wclk = 1'b0, rclk = 1'b0, arst_n = 1'b1;   // pulled low at t=1 (real reset edge)
  logic wrst_n, rrst_n;

  // Half periods are 64-bit variables: Verilator 5.020 miscompiles a delay
  // written as #(int / 2) (missing VL_SHIFTR_QII in generated C++).
  longint unsigned whalf_ps, rhalf_ps, rstart_ps;
  initial begin
    void'($value$plusargs("WCLK_PS=%d", wclk_ps));
    void'($value$plusargs("RCLK_PS=%d", rclk_ps));
    void'($value$plusargs("RPHASE_PS=%d", rphase_ps));
    void'($value$plusargs("CFG=%s", cfg));
    whalf_ps  = longint'(wclk_ps) >> 1;
    rhalf_ps  = longint'(rclk_ps) >> 1;
    rstart_ps = longint'(rphase_ps) + 1;
    fork
      forever #(whalf_ps) wclk = ~wclk;
      begin #(rstart_ps); forever #(rhalf_ps) rclk = ~rclk; end
    join_none
  end

  tflex_reset_sync u_wrs (.clk(wclk), .arst_n, .rst_n_o(wrst_n));
  tflex_reset_sync u_rrs (.clk(rclk), .arst_n, .rst_n_o(rrst_n));

  // ------------------------------------------------------------ DUT
  logic             w_valid = 1'b0, r_ready = 1'b0;
  logic             w_ready, r_valid;
  logic [WIDTH-1:0] w_data = '0, r_data;
  logic [ADDR_W:0]  w_count, w_rptr_bin, r_count;

  tflex_async_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
    .wclk, .wrst_n, .w_valid, .w_ready, .w_data, .w_count, .w_rptr_bin,
    .rclk, .rrst_n, .r_valid, .r_ready, .r_data, .r_count
  );

  // ------------------------------------------------------------ drivers
  typedef enum int {M_OFF, M_ON, M_RAND} mode_e;
  mode_e       wmode = M_OFF, rmode = M_OFF;
  int unsigned wpct = 100, rpct = 100;
  int unsigned w_target = 0;          // total words the writer may issue
  int unsigned w_issued = 0, w_accepted = 0, r_accepted = 0;
  logic [WIDTH-1:0] next_word = 32'h1000_0000;
  logic [WIDTH-1:0] sbq[$];
  int unsigned errors = 0;
  int unsigned full_stalls = 0, empty_cycles = 0, both_fire = 0;

  function automatic bit roll(int unsigned pct);
    return ($urandom % 100) < pct;
  endfunction

  // Drivers use asynchronous reset, like the RTL producers they stand in for.
  always @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      w_valid <= 1'b0;
    end else begin
      if (w_valid && w_ready) begin sbq.push_back(w_data); w_accepted++; end
      if (w_valid && !w_ready) full_stalls++;
      if (!w_valid || w_ready) begin
        if (w_issued < w_target && (wmode == M_ON || (wmode == M_RAND && roll(wpct)))) begin
          w_valid <= 1'b1; w_data <= next_word; next_word <= next_word + 1; w_issued++;
        end else begin
          w_valid <= 1'b0;
        end
      end
    end
  end

  always @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      r_ready <= 1'b0;
    end else begin
      if (r_valid && r_ready) begin
        if (sbq.size() == 0) begin
          $error("read with empty scoreboard"); errors++;
        end else begin
          logic [WIDTH-1:0] exp;
          exp = sbq.pop_front();
          if (r_data !== exp) begin $error("order/data mismatch: got %h exp %h", r_data, exp); errors++; end
        end
        r_accepted++;
      end
      if (!r_valid) empty_cycles++;
      if (r_valid && r_ready && w_valid && w_ready) both_fire++;
      r_ready <= (rmode == M_ON) || (rmode == M_RAND && roll(rpct));
    end
  end

  // ------------------------------------------------------------ helpers
  task automatic check(bit cond, string msg);
    if (!cond) begin $error("CHECK FAILED: %s", msg); errors++; end
  endtask

  task automatic wait_w(int n); repeat (n) @(posedge wclk); endtask
  task automatic wait_r(int n); repeat (n) @(posedge rclk); endtask

  task automatic wait_drained(int unsigned timeout_cycles);
    int unsigned t = 0;
    while ((w_issued != w_target || r_accepted != w_accepted || w_issued != w_accepted || r_valid)
           && t < timeout_cycles) begin
      @(posedge rclk); t++;
    end
    check(t < timeout_cycles, "drain timeout");
  endtask

  task automatic apply_reset();
    arst_n = 1'b0;
    wmode = M_OFF; rmode = M_OFF;
    #(longint'(10) * (wclk_ps + rclk_ps));
    sbq.delete();
    w_issued = 0; w_accepted = 0; r_accepted = 0; w_target = 0;
    arst_n = 1'b1;
    wait_w(4); wait_r(4);
  endtask

  // ------------------------------------------------------------ test sequence
  initial begin
    int unsigned accepted_before;
    #1;
    $display("tb_async_fifo: cfg=%s wclk=%0dps rclk=%0dps phase=%0dps DEPTH=%0d",
             cfg, wclk_ps, rclk_ps, rphase_ps, DEPTH);
    apply_reset();

    // T1: empty after reset
    wait_r(20);
    check(!r_valid, "T1 r_valid low when empty");
    check(w_ready, "T1 w_ready high when empty");
    check(w_count == 0 && r_count == 0, "T1 counts zero");

    // T2: fill to full with reader stopped
    w_target = DEPTH + 8; wmode = M_ON; rmode = M_OFF;
    wait_w(DEPTH + 40);
    check(w_accepted == DEPTH, $sformatf("T2 accepted exactly DEPTH words (got %0d)", w_accepted));
    check(!w_ready, "T2 w_ready low when full");
    check(w_count == DEPTH, "T2 w_count == DEPTH");
    wait_r(8);
    check(r_count == DEPTH, $sformatf("T2 r_count == DEPTH after sync (got %0d)", r_count));
    accepted_before = w_accepted;
    wait_w(20);
    check(w_accepted == accepted_before, "T2 no write accepted while full");

    // T3: drain; remaining 8 queued words enter as space frees; all in order
    rmode = M_ON;
    wait_drained(2000);
    wmode = M_OFF;
    check(sbq.size() == 0, "T3 scoreboard empty after drain");
    wait_r(8);
    check(!r_valid, "T3 r_valid low after drain (no underflow)");

    // T4: simultaneous read/write, sustained
    w_target = w_issued + 2000; wmode = M_ON; rmode = M_ON;
    wait_drained(20000);
    check(both_fire > 0, "T4 simultaneous read and write observed");

    // T5: random backpressure on both sides
    wpct = 70; rpct = 40;
    w_target = w_issued + 5000; wmode = M_RAND; rmode = M_RAND;
    wait_w(3000);
    rpct = 90;                                   // let it drain
    wait_drained(200000);
    wmode = M_OFF; rmode = M_ON;
    check(full_stalls > 0, "T5 full condition exercised");

    // T6: reset in the middle of traffic, then clean restart
    w_target = w_issued + 100000; wmode = M_ON; rmode = M_RAND; rpct = 30;
    wait_w(200);
    apply_reset();
    wait_r(10);
    check(!r_valid && w_ready && w_count == 0 && r_count == 0, "T6 FIFO empty after reset");
    w_target = 500; wmode = M_ON; rmode = M_ON;
    wait_drained(20000);
    check(sbq.size() == 0, "T6 traffic after reset delivered in order");

    $display("RESULT tb=async_fifo cfg=%s words_written=%0d full_stalls=%0d empty_cycles=%0d both_fire=%0d errors=%0d %s",
             cfg, next_word - 32'h1000_0000, full_stalls, empty_cycles, both_fire, errors,
             errors == 0 ? "PASS" : "FAIL");
    if (errors != 0) $fatal(1, "tb_async_fifo FAILED");
    $finish;
  end

  initial begin #(2_000_000_000); $fatal(1, "tb_async_fifo: global timeout"); end
endmodule
