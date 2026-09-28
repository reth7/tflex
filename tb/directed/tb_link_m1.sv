// =============================================================================
// tb_link_m1 -- Milestone 1 end-to-end test of one simplex D2D link:
//
//   clk_core: traffic_src -> packetizer ->|
//   clk_link:             TX FIFO -> adapter_tx -> phy_tx -> channel -> phy_rx
//                         -> adapter_rx -> RX FIFO (credits via sideband)
//   clk_mem:  ->| depacketizer -> traffic_sink (payload check)
//
// Plusargs: +TEST=<single|burst|sustained|backpressure|reset>
//           +CORE_PS= +LINK_PS= +MEM_PS= (clock periods)  +CFG=<label>
//           +SINK_PCT=<0..100> (backpressure test only) +NPKT=<n>
// Seeded with +verilator+seed+<n>.
//
// Checks: every packet arrives exactly once, in order, with correct header
// fields and payload (sink regenerates it); no framing or length errors; no
// credit violation; plus all bound assertions. Reports SIMULATED latency and
// throughput for the configuration it ran.
// =============================================================================
module tb_link_m1;
  import tflex_pkg::*;

  // ------------------------------------------------------------ configuration
  int unsigned core_ps = 1000, link_ps = 500, mem_ps = 1250;
  int unsigned sink_pct = 100, npkt = 0;
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
    void'($value$plusargs("TEST=%s", test));
    void'($value$plusargs("CFG=%s", cfg));
    hc = longint'(core_ps) >> 1; hl = longint'(link_ps) >> 1; hm = longint'(mem_ps) >> 1;
    fork   // 64-bit half periods: see note in tb_async_fifo.sv
      forever #(hc) clk_core = ~clk_core;
      begin #(longint'(137)); forever #(hl) clk_link = ~clk_link; end
      begin #(longint'(311)); forever #(hm) clk_mem  = ~clk_mem;  end
    join_none
  end

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
                           .CHANNEL_LATENCY(CH_LAT), .SB_LATENCY(SB_LAT)) u_link (
    .clk_src(clk_core), .rst_src_n(rst_core_n),
    .in_valid(pk_valid), .in_ready(pk_ready), .in_fb(pk_fb),
    .clk_link, .rst_link_n,
    .clk_dst(clk_mem), .rst_dst_n(rst_mem_n),
    .out_valid(lk_out_valid), .out_ready(lk_out_ready), .out_fb(lk_out_fb),
    .credits, .stat_flits_sent(st_sent), .stat_flits_rcvd(st_rcvd),
    .stat_stall_no_credit(st_stall), .overflow_err
  );

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
      default: begin $error("unknown TEST=%s", test); errors++; end
    endcase

    // let stray (erroneous) deliveries surface
    repeat (500) @(posedge clk_mem);
    if (lat_fd != 0) $fclose(lat_fd);

    begin
      real dur_ns, thr;
      dur_ns = (t_last - t_first) / 1000.0;
      thr    = (dur_ns > 0) ? payload_delivered / dur_ns : 0.0;   // bytes/ns = GB/s
      $display("RESULT tb=link_m1 test=%s cfg=%s core_ps=%0d link_ps=%0d mem_ps=%0d sink_pct=%0d pkts=%0d payload_B=%0d dur_ns=%.1f thr_GBps=%.3f lat_ns_min=%.1f lat_ns_mean=%.1f lat_ns_max=%.1f flits_sent=%0d flits_rcvd=%0d credit_stall_cyc=%0d txfifo_full_cyc=%0d errors=%0d %s",
               test, cfg, core_ps, link_ps, mem_ps, sink_pct, delivered, payload_delivered, dur_ns, thr,
               (delivered > 0) ? lat_min : 0.0, (delivered > 0) ? lat_sum / delivered : 0.0, lat_max,
               st_sent, st_rcvd, st_stall, fifo_full_seen, errors, (errors == 0 && s_sig == 0) ? "PASS" : "FAIL");
    end
    if (errors != 0 || s_sig != 0) $fatal(1, "tb_link_m1 FAILED");
    $finish;
  end
endmodule
