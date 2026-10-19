// =============================================================================
// tb_sb_mux -- seeded-random test of tflex_sb_mux (3 ports, port 0 highest).
// Each port offers numbered messages as a valid/ready stream (held until
// granted, checked by the bound tflex_stream_sva). Checks: every message is
// output exactly once and in order per port; the granted port is always the
// lowest-numbered requesting port; out_valid iff any request.
// Plusargs: +NMSG=<messages per port>; seeded with +verilator+seed+<n>.
// =============================================================================
module tb_sb_mux;
  import tflex_pkg::*;
  localparam int N = 3;

  logic clk = 1'b0, arst_n = 1'b1, rst_n;
  always #500 clk = ~clk;
  initial begin #1 arst_n = 1'b0; #5000 arst_n = 1'b1; end
  tflex_reset_sync u_rs (.clk, .arst_n, .rst_n_o(rst_n));

  logic    [N-1:0] req_valid, req_ready;
  sb_msg_t [N-1:0] req_msg;
  logic            out_valid;
  sb_msg_t         out_msg;

  tflex_sb_mux #(.N(N)) dut (.req_valid, .req_ready, .req_msg, .out_valid, .out_msg);

  for (genvar p = 0; p < N; p++) begin : g_src
    tflex_stream_sva #(.WIDTH($bits(sb_msg_t)), .NAME("sb_req")) u_sva (
      .clk, .rst_n, .valid(req_valid[p]), .ready(req_ready[p]), .data(req_msg[p])
    );
  end

  int unsigned nmsg = 2000, errors = 0, sent [N], rcvd [N], pct [N];
  logic [N-1:0] v_q;
  sb_msg_t [N-1:0] m_q;
  assign req_valid = v_q;
  assign req_msg   = m_q;

  // message of port p, number k: opcode distinguishes the port, arg = k
  function automatic sb_msg_t mk(int p, int unsigned k);
    return sb_make(sb_opcode_e'(SB_NAK - p), 40'(k));   // NAK, ACK, CREDIT... as port 0, 1, 2 (opcodes 9, 8, 7)
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_q <= '0; m_q <= '0;
      for (int p = 0; p < N; p++) begin sent[p] = 0; rcvd[p] = 0; end
    end else begin
      // check the combinational output for this cycle
      if (out_valid != (v_q != '0)) begin $error("out_valid %0b with requests %b", out_valid, v_q); errors++; end
      for (int p = 0; p < N; p++) begin
        logic hi;
        hi = 1'b0;
        for (int q = 0; q < p; q++) hi |= v_q[q];
        if (req_ready[p] != (v_q[p] && !hi)) begin $error("port %0d ready %0b, requests %b", p, req_ready[p], v_q); errors++; end
        if (v_q[p] && req_ready[p]) begin
          if (out_msg != m_q[p]) begin $error("port %0d: output %h, offered %h", p, out_msg, m_q[p]); errors++; end
          if (out_msg.arg != 40'(rcvd[p])) begin $error("port %0d: message %0d out of order (expected %0d)", p, out_msg.arg, rcvd[p]); errors++; end
          rcvd[p]++;
        end
      end
      // next offers: hold until granted, then maybe offer the next message
      for (int p = 0; p < N; p++) begin
        if (!v_q[p] || req_ready[p]) begin
          if (sent[p] < nmsg && ($urandom % 100) < pct[p]) begin
            v_q[p] <= 1'b1; m_q[p] <= mk(p, sent[p]); sent[p]++;
          end else v_q[p] <= 1'b0;
        end
      end
    end
  end

  initial begin
    void'($value$plusargs("NMSG=%d", nmsg));
    pct[0] = 20; pct[1] = 40; pct[2] = 60;      // total offered load > 1: lower ports must wait
    wait (rst_n);
    while (rcvd[0] + rcvd[1] + rcvd[2] < 3 * nmsg) begin
      @(posedge clk);
      if ($time > 64'd1_000_000_000) begin $error("timeout: %0d/%0d/%0d received", rcvd[0], rcvd[1], rcvd[2]); errors++; break; end
    end
    repeat (5) @(posedge clk);
    $display("RESULT tb=sb_mux msgs_per_port=%0d rcvd0=%0d rcvd1=%0d rcvd2=%0d errors=%0d %s",
             nmsg, rcvd[0], rcvd[1], rcvd[2], errors, (errors == 0) ? "PASS" : "FAIL");
    if (errors != 0) $fatal(1, "tb_sb_mux FAILED");
    $finish;
  end
endmodule
