// =============================================================================
// tflex_packetizer -- packet item stream -> flit bodies.
//
// Each item becomes one flit body; the flit type encodes packet framing
// (HEAD / DATA / TAIL / HEAD_TAIL). Items pass through combinationally
// (valid/ready forwarded), so the packetizer adds no latency or bubbles.
// len_err flags items whose framing disagrees with the header length; the
// flit is still forwarded (the error is for verification and statistics).
// Runs in the source clock domain (core or mem).
// =============================================================================
module tflex_packetizer
  import tflex_pkg::*;
(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       in_valid,
  output logic       in_ready,
  input  pkt_item_t  in_item,
  output logic       out_valid,
  input  logic       out_ready,
  output flit_body_t out_fb,
  output logic       len_err
);
  flit_type_e ft;

  always_comb begin
    unique case ({in_item.sop, in_item.eop})
      2'b11:   ft = FT_HEAD_TAIL;
      2'b10:   ft = FT_HEAD;
      2'b01:   ft = FT_TAIL;
      default: ft = FT_DATA;
    endcase
  end

  assign out_valid = in_valid;
  assign in_ready  = out_ready;
  assign out_fb    = '{ftype: ft, body: in_item.data};

  tflex_pkt_len_check u_chk (
    .clk, .rst_n,
    .fire  (in_valid && in_ready),
    .sop   (in_item.sop),
    .eop   (in_item.eop),
    .data  (in_item.data),
    .err   (len_err)
  );
endmodule
