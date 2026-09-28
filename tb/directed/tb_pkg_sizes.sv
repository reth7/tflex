// Phase 1 check: struct sizes in tflex_pkg match docs/protocol.md.
module tb_pkg_sizes;
  import tflex_pkg::*;
  int errors = 0;
  task automatic chk(string name, int got, int exp);
    if (got != exp) begin $error("%s: %0d bits, expected %0d", name, got, exp); errors++; end
    else $display("  ok  %-12s = %0d", name, got);
  endtask
  initial begin
    chk("flit_t",      $bits(flit_t),      FLIT_BITS);
    chk("pkt_hdr_t",   $bits(pkt_hdr_t),   BODY_BITS);
    chk("sb_msg_t",    $bits(sb_msg_t),    44);
    chk("fault_cmd_t", $bits(fault_cmd_t), 4 + PHYS_LANES + 3 + 32 + 24 + 32);
    chk("body bytes",  BODY_BYTES,         28);
    chk("lane idx w",  LANE_IDX_W,         6);
    chk("lanes*bits",  DATA_LANES * LANE_BITS, FLIT_BITS);
    chk("w(WM_24)",    int'(width_lanes(WM_24)), 24);
    if (errors == 0) $display("tb_pkg_sizes: PASS"); else $fatal(1, "tb_pkg_sizes: FAIL (%0d)", errors);
    $finish;
  end
endmodule
