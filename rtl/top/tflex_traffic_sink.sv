// =============================================================================
// tflex_traffic_sink -- packet sink with end-to-end payload checking
// (Milestone 1 stand-in for the memory models' receive side).
//
// Regenerates every expected payload word from (addr, tag, idx) and compares.
// At the end of each packet it pulses done_valid with the header and whether
// the whole packet matched. accept_en lets a testbench apply backpressure.
// =============================================================================
module tflex_traffic_sink
  import tflex_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        accept_en,
  input  logic        in_valid,
  output logic        in_ready,
  input  pkt_item_t   in_item,
  output logic        done_valid,     // one-cycle pulse per completed packet
  output pkt_hdr_t    done_hdr,
  output logic        done_ok,
  output logic [31:0] stat_pkts,
  output logic [31:0] stat_payload_bytes,
  output logic [31:0] stat_sig_errors,
  output logic [31:0] stat_orphan_items   // payload items with no open packet
);
  pkt_hdr_t    hdr_q;
  logic        open_q, ok_q;
  logic [16:0] rem_q;
  logic [15:0] idx_q;
  logic [5:0]  nbytes;
  logic        fire;
  logic [BODY_BITS-1:0] expected;

  assign in_ready = accept_en;
  assign fire     = in_valid && in_ready;
  assign nbytes   = (rem_q >= 17'(BODY_BYTES)) ? 6'(BODY_BYTES) : rem_q[5:0];
  assign expected = keep_bytes(payload_word(hdr_q.addr, hdr_q.tag, idx_q), nbytes);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hdr_q <= '0; open_q <= 1'b0; ok_q <= 1'b0; rem_q <= '0; idx_q <= '0;
      done_valid <= 1'b0; done_hdr <= '0; done_ok <= 1'b0;
      stat_pkts <= '0; stat_payload_bytes <= '0; stat_sig_errors <= '0; stat_orphan_items <= '0;
    end else begin
      done_valid <= 1'b0;
      if (fire) begin
        if (in_item.sop) begin
          pkt_hdr_t h;
          h = pkt_hdr_t'(in_item.data);
          hdr_q  <= h;
          rem_q  <= 17'(payload_len(h));
          idx_q  <= '0;
          ok_q   <= 1'b1;
          open_q <= !in_item.eop;
          if (in_item.eop) begin
            done_valid <= 1'b1; done_hdr <= h; done_ok <= 1'b1;
            stat_pkts  <= stat_pkts + 1;
          end
        end else if (!open_q) begin
          stat_orphan_items <= stat_orphan_items + 1;
        end else begin
          logic match;
          match = (in_item.data == expected);
          if (!match) stat_sig_errors <= stat_sig_errors + 1;
          stat_payload_bytes <= stat_payload_bytes + 32'(nbytes);
          rem_q <= (rem_q > 17'(BODY_BYTES)) ? rem_q - 17'(BODY_BYTES) : 17'd0;
          idx_q <= idx_q + 16'd1;
          if (in_item.eop) begin
            open_q     <= 1'b0;
            done_valid <= 1'b1; done_hdr <= hdr_q; done_ok <= ok_q && match;
            stat_pkts  <= stat_pkts + 1;
          end else if (!match) begin
            ok_q <= 1'b0;
          end
        end
      end
    end
  end
endmodule
