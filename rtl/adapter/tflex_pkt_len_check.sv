// =============================================================================
// tflex_pkt_len_check -- checks that a packet item stream is framed
// consistently with its header: a header (sop) item announces payload_len
// bytes; exactly ceil(len / BODY_BYTES) payload items must follow, the last one
// (and only it) flagged eop. Header-only packets are a single sop+eop item.
// Shared by the packetizer and the depacketizer.
// =============================================================================
module tflex_pkt_len_check
  import tflex_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 fire,      // item accepted this cycle
  input  logic                 sop,
  input  logic                 eop,
  input  logic [BODY_BITS-1:0] data,
  output logic                 err        // pulse: this item violates framing
);
  logic [16:0] rem_q;        // payload bytes still expected
  logic        in_pkt_q;
  logic [15:0] plen;
  logic        exp_eop;

  assign plen    = payload_len(pkt_hdr_t'(data));
  assign exp_eop = sop ? (plen == 16'd0) : (rem_q <= 17'(BODY_BYTES));

  always_comb begin
    err = 1'b0;
    if (fire) begin
      if (sop && in_pkt_q)   err = 1'b1;   // new header inside an open packet
      if (!sop && !in_pkt_q) err = 1'b1;   // payload without a header
      if (eop != exp_eop)    err = 1'b1;   // eop placement disagrees with length
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rem_q    <= '0;
      in_pkt_q <= 1'b0;
    end else if (fire) begin
      in_pkt_q <= !eop;
      if (sop) rem_q <= 17'(plen);
      else     rem_q <= (rem_q > 17'(BODY_BYTES)) ? rem_q - 17'(BODY_BYTES) : 17'd0;
    end
  end
endmodule
