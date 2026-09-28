// =============================================================================
// tflex_depacketizer -- flit bodies -> packet item stream.
//
// HEAD / HEAD_TAIL start a packet, TAIL / HEAD_TAIL end it, IDLE flits are
// consumed and dropped. framing_err pulses when the flit sequence is illegal
// (header inside an open packet, payload outside a packet, or eop placement
// inconsistent with the header length). Items still pass through so that the
// downstream checker sees what arrived. Runs in the destination clock domain.
// =============================================================================
module tflex_depacketizer
  import tflex_pkg::*;
(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       in_valid,
  output logic       in_ready,
  input  flit_body_t in_fb,
  output logic       out_valid,
  input  logic       out_ready,
  output pkt_item_t  out_item,
  output logic       framing_err
);
  logic is_idle, sop, eop, known;

  always_comb begin
    is_idle = 1'b0; sop = 1'b0; eop = 1'b0; known = 1'b1;
    unique case (in_fb.ftype)
      FT_IDLE:      is_idle = 1'b1;
      FT_HEAD:      sop = 1'b1;
      FT_DATA:      ;
      FT_TAIL:      eop = 1'b1;
      FT_HEAD_TAIL: begin sop = 1'b1; eop = 1'b1; end
      default:      known = 1'b0;          // reserved encodings
    endcase
  end

  // IDLE and reserved flits are consumed without producing an item.
  assign out_valid = in_valid && !is_idle && known;
  assign in_ready  = (is_idle || !known) ? 1'b1 : out_ready;
  assign out_item  = '{sop: sop, eop: eop, data: in_fb.body};

  logic len_err;
  tflex_pkt_len_check u_chk (
    .clk, .rst_n,
    .fire  (out_valid && out_ready),
    .sop, .eop,
    .data  (in_fb.body),
    .err   (len_err)
  );

  assign framing_err = len_err || (in_valid && !known);
endmodule
