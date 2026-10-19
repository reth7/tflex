// =============================================================================
// tb_link_m1 -- end-to-end tests of one simplex D2D link (Milestone 1 datapath
// tests; Milestone 2 retry, flow-control and fault-injection tests):
//
//   clk_core: traffic_src -> packetizer ->|
//   clk_link:             TX FIFO -> adapter_tx -> phy_tx -> channel -> phy_rx
//                         -> adapter_rx -> RX FIFO (credits via sideband)
//   clk_mem:  ->| depacketizer -> traffic_sink (payload check)
//
// Plusargs: +TEST=<single|burst|sustained|backpressure|reset|wave>     (M1)
//           +TEST=<crc1|bitflip|replay_corrupt|nak_first|nak_last|window|
//                  wrap|maxretry|spare_dead|nak_density|bp_recover|ber|dup> (M2)
//           +PPM=<per-flit corruption probability, ppm> (ber test)
//           +CORE_PS= +LINK_PS= +MEM_PS= (clock periods)  +CFG=<label>
//           +SINK_PCT=<0..100> (backpressure test only) +NPKT=<n>
//           +trace (only in a build with -DTFLEX_WAVE --trace-fst, `make wave`):
//           dump all signals to build/wave/link_m1_single.fst
// Seeded with +verilator+seed+<n>.
//
// Checks: every packet arrives exactly once, in order, with correct header
// fields and payload (sink regenerates it); no framing or length errors; no
// credit violation; plus all bound assertions. Reports SIMULATED latency and
// throughput for the configuration it ran. Every test also requires: no
// replay-timer expiry, and when nothing was injected no CRC error, NAK or
// replay. M2 tests target individual flits through the channel's fault
// injector and check the retry statistics (RESULT tb=link_m2).
// Parameters RETRY_D (replay-buffer depth) and REPLAY_TO (replay timeout) are
// overridden with -G for the window-full and duplicate tests.
// =============================================================================
module tb_link_m1 #(
  parameter int RETRY_D   = 64,
  parameter int REPLAY_TO = 256    // = link default 4 x (2 x (CH_LAT + SB_LAT) + 32); -G for the dup test
);
  import tflex_pkg::*;

  // ------------------------------------------------------------ configuration
  int unsigned core_ps = 1000, link_ps = 500, mem_ps = 1250;
  int unsigned sink_pct = 100, npkt = 0, ppm = 0;
  real         bp_thr1 = 0, bp_thr3 = 0;
  string       test = "single", cfg = "nominal";
  localparam int CH_LAT = 8, SB_LAT = 8, FIFO_D = 64;

  // arst_n starts high and is pulled low at t=1 so every async-reset flop sees
  // a real reset edge (a reset that is low from t=0 has no edge).
  logic clk_core = 0, clk_link = 0, clk_mem = 0, arst_n = 1;
  logic rst_core_n, rst_link_n, rst_mem_n;
  longint unsigned hc, hl, hm;

  initial begin
    void'($value$plusargs("CORE_PS=%d", core_ps));
    void'($value$plusargs("LINK_PS=%d", link_ps));
    void'($value$plusargs("MEM_PS=%d",  mem_ps));
    void'($value$plusargs("SINK_PCT=%d", sink_pct));
    void'($value$plusargs("NPKT=%d", npkt));
    void'($value$plusargs("PPM=%d", ppm));
    void'($value$plusargs("TEST=%s", test));
    void'($value$plusargs("CFG=%s", cfg));
    hc = longint'(core_ps) >> 1; hl = longint'(link_ps) >> 1; hm = longint'(mem_ps) >> 1;
    fork   // 64-bit half periods: see note in tb_async_fifo.sv
      forever #(hc) clk_core = ~clk_core;
      begin #(longint'(137)); forever #(hl) clk_link = ~clk_link; end
      begin #(longint'(311)); forever #(hm) clk_mem  = ~clk_mem;  end
    join_none
  end

`ifdef TFLEX_WAVE
  // Waveform dump for `make wave`; compiled out of the regression build.
  initial if ($test$plusargs("trace")) begin
    $dumpfile("build/wave/link_m1_single.fst");
    $dumpvars(0, tb_link_m1);
  end
`endif

  tflex_reset_sync u_rs_core (.clk(clk_core), .arst_n, .rst_n_o(rst_core_n));
  tflex_reset_sync u_rs_link (.clk(clk_link), .arst_n, .rst_n_o(rst_link_n));
  tflex_reset_sync u_rs_mem  (.clk(clk_mem),  .arst_n, .rst_n_o(rst_mem_n));

  // ------------------------------------------------------------ DUT chain
  logic       desc_valid = 0, desc_ready;
  pkt_hdr_t   desc_r = '0;
  logic       src_valid, src_ready, pk_valid, pk_ready, lk_out_valid, lk_out_ready;
  pkt_item_t  src_item, dp_item;
  flit_body_t pk_fb, lk_out_fb;
  logic       len_err, framing_err, overflow_err;
  logic [63:0] src_cycle;
  logic       dp_valid, dp_ready, accept_en = 1'b1;
  logic       done_valid, done_ok;
  pkt_hdr_t   done_hdr;
  logic [31:0] s_pkts, s_bytes, s_sig, s_orphan;
  logic [$clog2(FIFO_D):0] credits;
  logic [31:0] st_sent, st_rcvd, st_stall;
  retry_tx_stats_t tx_stats;
  retry_rx_stats_t rx_stats;
  logic        tx_retrain_req, rx_retrain_req;
  logic        fi_cmd_valid = 1'b0;            // fault injection (M2 tests only)
  logic [1:0]  fi_cmd_slot = '0;
  fault_cmd_t  fi_cmd = '0;
  logic [31:0] fi_cycle, fi_corrupted;

  tflex_traffic_src u_src (
    .clk(clk_core), .rst_n(rst_core_n),
    .desc_valid, .desc_ready, .desc(desc_r),
    .out_valid(src_valid), .out_ready(src_ready), .out_item(src_item), .cycle(src_cycle)
  );

  tflex_packetizer u_pkt (
    .clk(clk_core), .rst_n(rst_core_n),
    .in_valid(src_valid), .in_ready(src_ready), .in_item(src_item),
    .out_valid(pk_valid), .out_ready(pk_ready), .out_fb(pk_fb), .len_err
  );

  tflex_d2d_link_simplex #(.TX_FIFO_DEPTH(FIFO_D), .RX_FIFO_DEPTH(FIFO_D),
                           .CHANNEL_LATENCY(CH_LAT), .SB_LATENCY(SB_LAT),
                           .RETRY_DEPTH(RETRY_D), .REPLAY_TIMEOUT(REPLAY_TO)) u_link (
    .clk_src(clk_core), .rst_src_n(rst_core_n),
    .in_valid(pk_valid), .in_ready(pk_ready), .in_fb(pk_fb),
    .clk_link, .rst_link_n,
    .clk_dst(clk_mem), .rst_dst_n(rst_mem_n),
    .out_valid(lk_out_valid), .out_ready(lk_out_ready), .out_fb(lk_out_fb),
    .fi_cmd_valid, .fi_cmd_slot, .fi_cmd, .fi_cycle, .fi_corrupted,
    .credits, .tx_stats, .rx_stats, .tx_retrain_req, .rx_retrain_req, .overflow_err
  );
  assign st_sent  = tx_stats.flits_new + tx_stats.flits_replayed;
  assign st_rcvd  = rx_stats.flits_ok;
  assign st_stall = tx_stats.stall_no_credit;

  tflex_depacketizer u_depkt (
    .clk(clk_mem), .rst_n(rst_mem_n),
    .in_valid(lk_out_valid), .in_ready(lk_out_ready), .in_fb(lk_out_fb),
    .out_valid(dp_valid), .out_ready(dp_ready), .out_item(dp_item), .framing_err
  );

  tflex_traffic_sink u_sink (
    .clk(clk_mem), .rst_n(rst_mem_n), .accept_en,
    .in_valid(dp_valid), .in_ready(dp_ready), .in_item(dp_item),
    .done_valid, .done_hdr, .done_ok,
    .stat_pkts(s_pkts), .stat_payload_bytes(s_bytes), .stat_sig_errors(s_sig),
    .stat_orphan_items(s_orphan)
  );

  // ------------------------------------------------------------ scoreboard
  pkt_hdr_t    pend_q[$];          // descriptors not yet offered
  pkt_hdr_t    exp_q[$];           // accepted by the source, awaiting delivery
  realtime     t_inj[int];         // by tag
  int unsigned errors = 0, delivered = 0, accepted = 0;
  longint unsigned payload_delivered = 0;
  realtime     t_first = 0, t_last = 0;
  real         lat_sum = 0, lat_min = 1e18, lat_max = 0;
  bit          gate_one_at_a_time = 0;
  int unsigned fifo_full_seen = 0;
  int          lat_fd = 0;

  // descriptor driver (core domain, async reset like RTL producers)
  always @(posedge clk_core or negedge rst_core_n) begin
    if (!rst_core_n) begin
      desc_valid <= 1'b0;
    end else begin
      if (desc_valid && desc_ready) begin
        exp_q.push_back(desc_r);
        t_inj[int'(desc_r.tag)] = $realtime;
        if (accepted == 0) t_first = $realtime;
        accepted++;
      end
      if (!desc_valid || desc_ready) begin
        if (pend_q.size() > 0 && (!gate_one_at_a_time || (exp_q.size() == 0 && !(desc_valid && desc_ready)))) begin
          desc_r     <= pend_q.pop_front();
          desc_valid <= 1'b1;
        end else begin
          desc_valid <= 1'b0;
        end
      end
      if (pk_valid && !pk_ready) fifo_full_seen++;
    end
  end

  // delivery monitor (mem domain)
  always @(posedge clk_mem) begin
    if (rst_mem_n) begin
      if (done_valid) begin
        if (exp_q.size() == 0) begin
          $error("delivered packet tag %0d was never sent (duplicate?)", done_hdr.tag); errors++;
        end else begin
          pkt_hdr_t e;
          real lat;
          e = exp_q.pop_front();
          if (done_hdr.tag != e.tag || done_hdr.addr != e.addr || done_hdr.len != e.len ||
              done_hdr.ptype != e.ptype || done_hdr.src != e.src || done_hdr.dst != e.dst) begin
            $error("order/header mismatch: got tag %0d exp tag %0d", done_hdr.tag, e.tag); errors++;
          end
          if (!done_ok) begin $error("payload mismatch in tag %0d", done_hdr.tag); errors++; end
          lat = ($realtime - t_inj[int'(e.tag)]) / 1000.0;    // ns
          lat_sum += lat; if (lat < lat_min) lat_min = lat; if (lat > lat_max) lat_max = lat;
          if (lat_fd != 0) $fdisplay(lat_fd, "%0d,%0d,%0d,%.3f", e.tag, e.ptype, payload_len(e), lat);
          payload_delivered += payload_len(e);
          t_last = $realtime;
          delivered++;
        end
      end
      if (len_err)      begin $error("packetizer length error");  errors++; end
      if (framing_err)  begin $error("depacketizer framing error"); errors++; end
      if (s_orphan != 0) begin $error("sink saw orphan payload"); errors++; end
    end
  end

  always @(posedge clk_link) if (rst_link_n && overflow_err) begin $error("RX overflow"); errors++; end

  // backpressure pattern at the sink
  always @(posedge clk_mem) accept_en <= (sink_pct >= 100) ? 1'b1 : (($urandom % 100) < sink_pct);


  // ------------------------------------------------------------ fault targeting (M2)
  // The TB sees the retry TX's send decision in the cycle before the flit is
  // registered; the flit then spends one cycle in the PHY TX register and
  // reaches the injector's input two edges after this sample. A one-shot
  // command written now (start_cycle 0 = "next valid beat") is loaded at the
  // next edge and therefore acts on exactly that flit.
  int unsigned t_new_idx[$];          // corrupt these new-flit indices (ascending)
  int unsigned t_empty_n = 0;         // ... the next n new flits sent with an empty window
  int unsigned t_full_n = 0;          // ... the next n new flits that fill the window
  int unsigned t_replay_n = 0;        // ... the next n replayed flits after the first hit
  int unsigned t_ppm = 0;             // ... any transmitted flit with this probability (ppm)
  fault_mode_e t_mode = FM_CRC_CORRUPT;
  bit          dead_req = 0;          // issue dead_cmd (lane failure) once
  fault_cmd_t  dead_cmd = '0;
  bit          detect_all = 1;        // every corrupted beat must be a CRC error
  int unsigned new_cnt = 0, inj_cnt = 0, slot_rr = 0;
  logic [7:0]  inj_seq[$];            // sequence numbers of corrupted flits
  bit          replay_armed = 0;

  always @(posedge clk_link) begin
    fi_cmd_valid <= 1'b0;
    if (rst_link_n) begin
      if (dead_req) begin
        dead_req     = 0;
        fi_cmd       <= dead_cmd;
        fi_cmd_slot  <= 2'(slot_rr++);
        fi_cmd_valid <= 1'b1;
      end else if (u_link.u_retry_tx.send) begin
        bit hit;
        hit = 0;
        if (u_link.u_retry_tx.send_new) begin
          if (t_new_idx.size() != 0 && t_new_idx[0] == new_cnt) begin hit = 1; void'(t_new_idx.pop_front()); end
          if (t_empty_n != 0 && u_link.u_retry_tx.outstanding == 0)                 begin hit = 1; t_empty_n--; end
          if (t_full_n != 0 && u_link.u_retry_tx.outstanding == 8'(RETRY_D - 1))    begin hit = 1; t_full_n--; end
          new_cnt++;
        end else if (replay_armed && t_replay_n != 0) begin
          hit = 1; t_replay_n--;
        end
        if (t_ppm != 0) begin                 // draw only in the ber test (keeps other tests' random streams)
          if (($urandom % 1_000_000) < t_ppm) hit = 1;
        end
        if (hit) begin
          // Random values go through temporaries and the command is built as a whole:
          // a $urandom on the right of a packed-struct member write is evaluated more
          // than once by the simulator in use (verification.md section 5).
          int unsigned lane, bidx;
          lane = $urandom % DATA_LANES;
          bidx = $urandom % LANE_BITS;
          fi_cmd       <= '{mode: t_mode, lane_mask: (t_mode == FM_BIT_FLIP) ? 36'(1) << lane : '0,
                            bit_idx: 3'(bidx), start_cycle: '0, duration: '0, ber_thresh: '0};
          fi_cmd_slot  <= 2'(slot_rr++);
          fi_cmd_valid <= 1'b1;
          inj_seq.push_back(u_link.u_retry_tx.send_ptr);
          inj_cnt++;
          replay_armed = 1;
        end
      end
    end
  end

  // ------------------------------------------------------------ retry monitors (M2)
  // retry latency = first NAK of a sequence -> delivery of that sequence
  realtime     t_nak[int];
  real         rl_sum = 0, rl_max = 0;
  int unsigned rl_n = 0, replay_wraps = 0;
  logic [7:0]  nak_seq[$];            // sequence of every first (non-resent) NAK
  logic [7:0]  last_replay_seq = 0;
  bit          last_was_replay = 0;

  always @(posedge clk_link) begin
    if (rst_link_n) begin
      if (u_link.u_retry_rx.nak_load && u_link.u_retry_rx.nak_new) begin
        nak_seq.push_back(u_link.u_retry_rx.expected_q);
        if (!t_nak.exists(int'(u_link.u_retry_rx.expected_q))) t_nak[int'(u_link.u_retry_rx.expected_q)] = $realtime;
      end
      if (u_link.u_retry_rx.deliver && t_nak.exists(int'(u_link.prx_flit.seq))) begin
        real l;
        l = ($realtime - t_nak[int'(u_link.prx_flit.seq)]) / 1000.0;
        rl_sum += l; rl_n++; if (l > rl_max) rl_max = l;
        t_nak.delete(int'(u_link.prx_flit.seq));
      end
      if (u_link.u_retry_tx.send_replay) begin
        if (last_was_replay && last_replay_seq == 8'hFF && u_link.u_retry_tx.send_ptr == 8'h00) replay_wraps++;
        last_replay_seq = u_link.u_retry_tx.send_ptr;
      end
      last_was_replay = u_link.u_retry_tx.send_replay;
    end
  end

  // retrain requests as seen on the link outputs (one-cycle pulses)
  int unsigned tx_rt_pulses = 0, rx_rt_pulses = 0;
  always @(posedge clk_link) if (rst_link_n) begin
    if (tx_retrain_req) tx_rt_pulses++;
    if (rx_retrain_req) rx_rt_pulses++;
  end

  // throughput windows for bp_recover (mem domain)
  realtime     bp_t [4];
  longint unsigned bp_b [4];
  int unsigned bp_k = 0;
  always @(posedge clk_mem) begin
    if (test == "bp_recover" && bp_k != 0) begin
      if (delivered == bp_k / 4 && bp_t[0] == 0)         begin bp_t[0] = $realtime; bp_b[0] = payload_delivered; end
      if (delivered == bp_k && bp_t[1] == 0)             begin bp_t[1] = $realtime; bp_b[1] = payload_delivered; sink_pct = 20; end
      if (delivered == 2 * bp_k && sink_pct != 100)      sink_pct = 100;
      if (delivered == 2 * bp_k + bp_k / 4 && bp_t[2] == 0) begin bp_t[2] = $realtime; bp_b[2] = payload_delivered; end
      if (delivered == 3 * bp_k && bp_t[3] == 0)         begin bp_t[3] = $realtime; bp_b[3] = payload_delivered; end
    end
  end

  task automatic expect_eq(string what, longint unsigned got, longint unsigned exp);
    if (got != exp) begin $error("%s: %0d, expected %0d", what, got, exp); errors++; end
  endtask
  task automatic expect_ge(string what, longint unsigned got, longint unsigned lo);
    if (got < lo) begin $error("%s: %0d, expected >= %0d", what, got, lo); errors++; end
  endtask
  task automatic expect_nak_seqs();     // every first NAK names a corrupted flit, in order
    for (int i = 0; i < nak_seq.size(); i++)
      if (i >= inj_seq.size() || nak_seq[i] != inj_seq[i]) begin
        $error("NAK %0d names seq %0d, corrupted flit was seq %0d", i, nak_seq[i], (i < inj_seq.size()) ? inj_seq[i] : -1);
        errors++;
      end
  endtask

  // ------------------------------------------------------------ helpers
  int unsigned tag_ctr = 1;
  function automatic pkt_hdr_t mk(pkt_type_e pt, int unsigned len);
    pkt_hdr_t h;
    h = '0;
    h.src    = NODE_AI;
    h.dst    = NODE_SRAM;
    h.ptype  = pt;
    h.tclass = TC_ACTIVATION;
    h.len    = 16'(len);
    h.tag    = 16'(tag_ctr);
    h.addr   = 48'h0000_1000_0000 + 48'(tag_ctr) * 48'h1_0000;
    tag_ctr++;
    return h;
  endfunction

  function automatic pkt_hdr_t mk_rand(int unsigned maxlen);
    int unsigned r;
    r = $urandom % 8;
    if (r == 0) return mk(PT_RD_REQ, 1 + ($urandom % maxlen));     // header-only
    return mk(PT_WR_REQ, 1 + ($urandom % maxlen));
  endfunction

  task automatic run_until_done(realtime timeout_ns);
    realtime t0;
    t0 = $realtime;
    while ((pend_q.size() != 0 || exp_q.size() != 0 || desc_valid) && ($realtime - t0) < timeout_ns * 1000.0)
      @(posedge clk_mem);
    if (pend_q.size() != 0 || exp_q.size() != 0) begin
      $error("timeout: %0d pending, %0d in flight", pend_q.size(), exp_q.size()); errors++;
    end
  endtask

  task automatic do_reset();
    arst_n = 1'b0;
    #(longint'(20) * (core_ps + link_ps + mem_ps));
    pend_q.delete(); exp_q.delete();
    arst_n = 1'b1;
    repeat (5) @(posedge clk_mem);
  endtask

  // ------------------------------------------------------------ tests
  initial begin
    #1;
    $display("tb_link_m1: test=%s cfg=%s core=%0dps link=%0dps mem=%0dps sink=%0d%%",
             test, cfg, core_ps, link_ps, mem_ps, sink_pct);
    do_reset();

    case (test)
      "single": begin
        // Idle link, one packet at a time: per-packet latency by size.
        int unsigned lens[$] = '{0, 1, 27, 28, 29, 56, 57, 256, 1024, 4096, 65535};
        lat_fd = $fopen($sformatf("build/m1_latency_%s.csv", cfg), "w");
        if (lat_fd != 0) $fdisplay(lat_fd, "tag,ptype,payload_bytes,latency_ns");
        gate_one_at_a_time = 1;
        pend_q.push_back(mk(PT_RD_REQ, 64));
        foreach (lens[i]) pend_q.push_back(mk(PT_WR_REQ, lens[i]));
        run_until_done(1_000_000);
      end
      "wave": begin
        // Short `single`-style run for waveform viewing: one 256 B write, then
        // one 4096 B write, each on an idle link.
        gate_one_at_a_time = 1;
        pend_q.push_back(mk(PT_WR_REQ, 256));
        pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(1_000_000);
      end
      "burst": begin
        // Back-to-back burst, random sizes, then idle, then a second burst.
        int unsigned n = (npkt != 0) ? npkt : 64;
        repeat (n) pend_q.push_back(mk_rand(512));
        run_until_done(10_000_000);
        repeat (2000) @(posedge clk_mem);
        repeat (n) pend_q.push_back(mk_rand(512));
        run_until_done(10_000_000);
      end
      "sustained": begin
        // Long stream of 4 KiB writes: throughput under saturation.
        int unsigned n = (npkt != 0) ? npkt : 1000;
        repeat (n) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(100_000_000);
      end
      "backpressure": begin
        // Slow, random consumer: FIFOs fill, credits run out, nothing is lost.
        int unsigned n = (npkt != 0) ? npkt : 500;
        repeat (n) pend_q.push_back(mk_rand(1024));
        run_until_done(100_000_000);
        if (fifo_full_seen == 0) begin $error("backpressure test never filled the TX FIFO"); errors++; end
        if (st_stall == 0)       begin $error("backpressure test never ran out of credits"); errors++; end
      end
      "reset": begin
        // Reset all domains mid-stream, then verify a clean restart.
        repeat (200) pend_q.push_back(mk(PT_WR_REQ, 1024));
        repeat (3000) @(posedge clk_core);
        if (exp_q.size() == 0) begin $error("reset test: no traffic in flight at reset"); errors++; end
        do_reset();
        repeat (20) @(posedge clk_link);
        if (credits != FIFO_D) begin $error("credits not restored by reset (%0d)", credits); errors++; end
        if (lk_out_valid)      begin $error("RX FIFO not empty after reset"); errors++; end
        delivered = 0; payload_delivered = 0; lat_sum = 0; lat_min = 1e18; lat_max = 0; accepted = 0;
        repeat (100) pend_q.push_back(mk_rand(1024));
        run_until_done(10_000_000);
      end
      // ---------------------------------------------------- Milestone 2
      "crc1": begin
        // One flit with a corrupted CRC in a stream: one NAK, one replay, no loss.
        t_new_idx.push_back(50 + $urandom % 1000);
        repeat (60) pend_q.push_back(mk(PT_WR_REQ, 1024));
        run_until_done(10_000_000);
        expect_eq("crc_errors", rx_stats.crc_errors, 1);
        expect_eq("naks_sent", rx_stats.naks_sent, 1);
        expect_eq("replay_events", tx_stats.replay_events, 1);
        expect_nak_seqs();
      end
      "bitflip": begin
        // Ten single-bit errors on random lanes/bits, spaced beyond one round trip.
        int unsigned idx = 0;
        t_mode = FM_BIT_FLIP;
        repeat (10) begin idx += 100 + $urandom % 400; t_new_idx.push_back(idx); end
        repeat (200) pend_q.push_back(mk(PT_WR_REQ, 1024));
        run_until_done(100_000_000);
        expect_eq("corrupted flits", fi_corrupted, 10);
        expect_eq("naks_sent", rx_stats.naks_sent, 10);
        expect_nak_seqs();
      end
      "replay_corrupt": begin
        // The flit and its first replay are corrupted: the pending NAK is re-sent.
        t_new_idx.push_back(100 + $urandom % 500);
        t_replay_n = 1;
        repeat (60) pend_q.push_back(mk(PT_WR_REQ, 1024));
        run_until_done(10_000_000);
        expect_eq("crc_errors", rx_stats.crc_errors, 2);
        expect_eq("first NAKs", nak_seq.size(), 1);
        expect_ge("nak_resends", rx_stats.nak_resends, 1);
        expect_ge("replay_events", tx_stats.replay_events, 2);
        if (inj_seq.size() == 2 && inj_seq[0] != inj_seq[1]) begin $error("second corruption did not hit the replay of seq %0d", inj_seq[0]); errors++; end
        expect_nak_seqs();
      end
      "nak_first": begin
        // Corrupt the oldest flit of the window: packets on an idle, fully ACKed link.
        t_empty_n = 5;
        repeat (5) begin
          pend_q.push_back(mk(PT_WR_REQ, 256));
          run_until_done(1_000_000);
          repeat (100) @(posedge clk_mem);
        end
        expect_eq("corrupted flits", inj_cnt, 5);
        expect_eq("naks_sent", rx_stats.naks_sent, 5);
        expect_nak_seqs();
      end
      "nak_last": begin
        // Corrupt the flit that fills the replay window (small RETRY_D build).
        t_full_n = 5;
        repeat (40) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(100_000_000);
        expect_eq("corrupted flits", inj_cnt, 5);
        expect_ge("stall_window_full", tx_stats.stall_window_full, 1);
        expect_nak_seqs();
      end
      "window": begin
        // Window-limited sustained traffic, no faults (small RETRY_D build).
        repeat (40) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(100_000_000);
        expect_ge("stall_window_full", tx_stats.stall_window_full, 1);
      end
      "wrap": begin
        // Errors after sequence wrap-around: seq 250 on the 2nd lap (replay crosses 255 -> 0)
        // and seq 0 on the 4th lap.
        t_new_idx.push_back(256 + 250);
        t_new_idx.push_back(3 * 256);
        repeat (8) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(100_000_000);
        if (inj_seq.size() != 2 || inj_seq[0] != 8'd250 || inj_seq[1] != 8'd0) begin $error("wrap: corrupted seqs not 250, 0"); errors++; end
        expect_ge("replays crossing 255->0", replay_wraps, 1);
        expect_nak_seqs();
      end
      "maxretry": begin
        // Selected lane failure (transient, 1000 cycles): every flit on the lane fails,
        // the same flit is NAKed more than MAX_RETRY times -> retrain request; traffic
        // recovers with no loss once the lane works again.
        int unsigned lane;
        lane = $urandom % DATA_LANES;
        dead_cmd = '{mode: FM_LANE_DEAD, lane_mask: 36'(1) << lane, bit_idx: '0,
                     start_cycle: fi_cycle + 300, duration: 24'd1000, ber_thresh: '0};
        dead_req = 1;
        repeat (12) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(100_000_000);
        expect_ge("tx retrain requests", tx_rt_pulses, 1);
        expect_ge("crc_errors", rx_stats.crc_errors, 1);
      end
      "spare_dead": begin
        // A failed spare lane carries no data (no repair until M3): no error, no retry.
        int unsigned lane;
        lane = DATA_LANES + $urandom % SPARE_LANES;
        dead_cmd = '{mode: FM_LANE_DEAD, lane_mask: 36'(1) << lane, bit_idx: '0,
                     start_cycle: fi_cycle + 50, duration: '0, ber_thresh: '0};
        dead_req = 1;
        detect_all = 0;
        repeat (20) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(100_000_000);
        expect_ge("corrupted beats (spare lane)", fi_corrupted, 1);
        expect_eq("crc_errors", rx_stats.crc_errors, 0);
        expect_eq("flits_replayed", tx_stats.flits_replayed, 0);
      end
      "nak_density": begin
        // Many independent errors, each fixed by one replay: no flit exceeds MAX_RETRY,
        // but >= 16 NAKs within 256 received flits -> RX retrain request.
        for (int i = 0; i < 20; i++) t_new_idx.push_back(i);
        gate_one_at_a_time = 1;
        repeat (30) pend_q.push_back(mk(PT_RD_REQ, 64));
        run_until_done(10_000_000);
        expect_eq("corrupted flits", inj_cnt, 20);
        expect_ge("rx retrain requests", rx_rt_pulses, 1);
        expect_eq("tx retrain requests", tx_rt_pulses, 0);
      end
      "bp_recover": begin
        // Throughput before back-pressure, during a 20 % sink, and after it ends.
        bp_k = (npkt != 0) ? npkt : 60;
        for (int i = 0; i < 4; i++) begin bp_t[i] = 0; bp_b[i] = 0; end
        repeat (3 * bp_k) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(100_000_000);
        repeat (4) @(posedge clk_mem);    // let the window monitor record the last delivery
        begin
          real thr1, thr3, bound;
          int unsigned slow_ps;
          thr1 = (bp_b[1] - bp_b[0]) / ((bp_t[1] - bp_t[0]) / 1000.0);
          thr3 = (bp_b[3] - bp_b[2]) / ((bp_t[3] - bp_t[2]) / 1000.0);
          // analytical bound: one flit per cycle of the slowest clock, 4096 B per 148 flits
          slow_ps = (core_ps > link_ps) ? core_ps : link_ps;
          if (mem_ps > slow_ps) slow_ps = mem_ps;
          bound = (4096.0 / 148.0) * 1000.0 / real'(slow_ps);
          $display("bp_recover: before %.3f GB/s, after %.3f GB/s, bound %.3f GB/s", thr1, thr3, bound);
          bp_thr1 = thr1; bp_thr3 = thr3;
          if (!(thr1 >= 0.99 * bound)) begin $error("throughput before back-pressure %.3f GB/s < 99%% of bound %.3f", thr1, bound); errors++; end
          if (!(thr3 >= 0.99 * bound)) begin $error("throughput did not recover: %.3f GB/s < 99%% of bound %.3f", thr3, bound); errors++; end
        end
        expect_ge("credit stalls", tx_stats.stall_no_credit, 1);
      end
      "dup": begin
        // Replay timeout shorter than the ACK round trip (REPLAY_TO build): the timer
        // replays flits the receiver already has. They must be dropped as duplicates.
        gate_one_at_a_time = 1;
        repeat (10) pend_q.push_back(mk(PT_RD_REQ, 64));
        run_until_done(1_000_000);
        gate_one_at_a_time = 0;
        repeat (20) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(100_000_000);
        expect_ge("replay timeouts", tx_stats.replay_timeouts, 1);
        expect_ge("duplicates dropped", rx_stats.duplicates, 1);
      end
      "ber": begin
        // Random single-bit errors on any transmitted flit (new or replay), p = PPM / 1e6.
        t_mode = FM_BIT_FLIP;
        t_ppm  = ppm;
        repeat ((npkt != 0) ? npkt : 100) pend_q.push_back(mk(PT_WR_REQ, 4096));
        run_until_done(1_000_000_000);
        t_ppm = 0;
      end
      default: begin $error("unknown TEST=%s", test); errors++; end
    endcase

    // let stray (erroneous) deliveries surface
    repeat (500) @(posedge clk_mem);
    if (lat_fd != 0) $fclose(lat_fd);

    // checks common to every test
    if (test != "dup") expect_eq("replay timer expiries", tx_stats.replay_timeouts, 0);
    expect_eq("tx retrain pulses vs counter", tx_rt_pulses, tx_stats.retrain_reqs);
    expect_eq("rx retrain pulses vs counter", rx_rt_pulses, rx_stats.retrain_reqs);
    if (fi_corrupted == 0) begin
      expect_eq("crc_errors without faults", rx_stats.crc_errors, 0);
      expect_eq("NAKs without faults", rx_stats.naks_sent, 0);
      if (test != "dup") expect_eq("replays without faults", tx_stats.flits_replayed, 0);
    end else if (detect_all) begin
      expect_eq("crc_errors vs corrupted flits", rx_stats.crc_errors, fi_corrupted);
    end

    begin
      real dur_ns, thr;
      bit  m2;
      m2     = !(test inside {"single", "burst", "sustained", "backpressure", "reset", "wave"});
      dur_ns = (t_last - t_first) / 1000.0;
      thr    = (dur_ns > 0) ? payload_delivered / dur_ns : 0.0;   // bytes/ns = GB/s
      if (!m2)
      $display("RESULT tb=link_m1 test=%s cfg=%s core_ps=%0d link_ps=%0d mem_ps=%0d sink_pct=%0d pkts=%0d payload_B=%0d dur_ns=%.1f thr_GBps=%.3f lat_ns_min=%.1f lat_ns_mean=%.1f lat_ns_max=%.1f flits_sent=%0d flits_rcvd=%0d credit_stall_cyc=%0d txfifo_full_cyc=%0d errors=%0d %s",
               test, cfg, core_ps, link_ps, mem_ps, sink_pct, delivered, payload_delivered, dur_ns, thr,
               (delivered > 0) ? lat_min : 0.0, (delivered > 0) ? lat_sum / delivered : 0.0, lat_max,
               st_sent, st_rcvd, st_stall, fifo_full_seen, errors, (errors == 0 && s_sig == 0) ? "PASS" : "FAIL");
      else
      $display("RESULT tb=link_m2 test=%s cfg=%s retry_depth=%0d ppm=%0d core_ps=%0d link_ps=%0d mem_ps=%0d pkts=%0d payload_B=%0d dur_ns=%.1f thr_GBps=%.3f lat_ns_mean=%.1f lat_ns_max=%.1f flits_new=%0d flits_replayed=%0d retry_overhead=%.4f corrupted=%0d crc_errors=%0d naks=%0d nak_resends=%0d acks=%0d gaps=%0d dups=%0d replay_events=%0d replay_timeouts=%0d tx_retrain=%0d rx_retrain=%0d retry_lat_n=%0d retry_lat_ns_mean=%.1f retry_lat_ns_max=%.1f window_stall_cyc=%0d credit_stall_cyc=%0d bp_thr_before=%.3f bp_thr_after=%.3f errors=%0d %s",
               test, cfg, RETRY_D, ppm, core_ps, link_ps, mem_ps, delivered, payload_delivered, dur_ns, thr,
               (delivered > 0) ? lat_sum / delivered : 0.0, lat_max,
               tx_stats.flits_new, tx_stats.flits_replayed,
               (tx_stats.flits_new != 0) ? real'(tx_stats.flits_replayed) / real'(tx_stats.flits_new) : 0.0,
               fi_corrupted, rx_stats.crc_errors, rx_stats.naks_sent, rx_stats.nak_resends, rx_stats.acks_sent,
               rx_stats.seq_gaps, rx_stats.duplicates, tx_stats.replay_events, tx_stats.replay_timeouts,
               tx_stats.retrain_reqs, rx_stats.retrain_reqs,
               rl_n, (rl_n > 0) ? rl_sum / rl_n : 0.0, rl_max,
               tx_stats.stall_window_full, tx_stats.stall_no_credit, bp_thr1, bp_thr3,
               errors, (errors == 0 && s_sig == 0) ? "PASS" : "FAIL");
    end
    if (errors != 0 || s_sig != 0) $fatal(1, "tb_link_m1 FAILED");
    $finish;
  end
endmodule
