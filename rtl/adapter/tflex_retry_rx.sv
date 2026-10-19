// =============================================================================
// tflex_retry_rx -- link-layer receiver: CRC check, sequence check, in-order
// delivery, ACK coalescing and NAK generation (docs/protocol.md section 4.2).
// Replaces the Milestone 1 tflex_adapter_rx.
//
//   received flit                    action
//   bad CRC (any apparent ftype)     drop; NAK(expected) unless one is pending
//   good CRC, IDLE                   drop, not sequenced
//   good CRC, seq == expected        deliver to the RX FIFO, expected++,
//                                    clear NAK-pending
//   good CRC, seq behind expected    duplicate (from a replay): drop
//   good CRC, seq ahead of expected  gap: drop; NAK(expected) unless pending
//
// ACKs are cumulative ACK(last delivered), sent after ACK_FLITS deliveries or
// after ACK_IDLE cycles without a delivery while deliveries are unacknowledged.
// A pending NAK is re-sent every NAK_RESEND cycles (covers a corrupted replay
// of the NAKed flit; must exceed the NAK -> replay round trip).
// NAK density: >= NAK_WIN_LIMIT NAKs within a window of NAK_WIN_FLITS received
// flits raises retrain_req (RR_CRC_BURST) once per window.
//
// The receiver never back-pressures the PHY: credits guarantee RX FIFO space
// for every delivered flit; a violation is flagged on overflow_err (and
// asserted against). Flit acceptance is combinational (no added latency).
// =============================================================================
module tflex_retry_rx
  import tflex_pkg::*;
#(
  parameter int  ACK_FLITS     = 8,
  parameter int  ACK_IDLE      = 16,
  parameter int  NAK_RESEND    = 64,
  parameter int  NAK_WIN_FLITS = 256,
  parameter int  NAK_WIN_LIMIT = 16,
  localparam int AW            = $clog2(ACK_FLITS + 1),
  localparam int IDW           = $clog2(ACK_IDLE + 1),
  localparam int RW            = $clog2(NAK_RESEND + 1),
  localparam int WW            = $clog2(NAK_WIN_FLITS + 1),
  localparam int LW            = $clog2(NAK_WIN_LIMIT + 1)
) (
  input  logic            clk,
  input  logic            rst_n,
  // from PHY
  input  logic            in_valid,
  input  flit_t           in_flit,
  // to RX FIFO (write side)
  output logic            fifo_valid,
  input  logic            fifo_ready,
  output flit_body_t      fifo_fb,
  // sideband requests (to tflex_sb_mux)
  output logic            ack_valid,
  input  logic            ack_ready,
  output sb_msg_t         ack_msg,
  output logic            nak_valid,
  input  logic            nak_ready,
  output sb_msg_t         nak_msg,
  // status
  output logic            overflow_err,
  output logic            retrain_req,     // one-cycle pulse
  output retrain_reason_e retrain_reason,
  output retry_rx_stats_t stats
);
  typedef logic [SEQ_BITS-1:0] seq_t;

  seq_t           expected_q;
  logic           nak_pending_q;
  logic [RW-1:0]  nak_timer_q;
  logic [AW-1:0]  unacked_q;
  logic [IDW-1:0] idle_q;
  logic [WW-1:0]  win_q;
  logic [LW-1:0]  win_naks_q;

  // ------------------------------------------------------------ classify
  logic [CRC_BITS-1:0] crc_calc;
  logic                crc_ok, good, bad, is_idle, deliver, dup, gap;
  seq_t                d;

  tflex_crc #(.DATA_W(FLIT_BITS - CRC_BITS), .CRC_W(CRC_BITS), .POLY(CRC_POLY), .INIT(CRC_INIT)) u_crc (
    .data(in_flit[FLIT_BITS-1:CRC_BITS]), .crc(crc_calc)
  );

  assign crc_ok  = crc_calc == in_flit.crc;
  assign good    = in_valid && crc_ok;
  assign bad     = in_valid && !crc_ok;
  assign is_idle = in_flit.ftype == FT_IDLE;
  assign d       = in_flit.seq - expected_q;                  // 0: in order; MSB set: behind
  assign deliver = good && !is_idle && d == '0;
  assign dup     = good && !is_idle && d[SEQ_BITS-1];
  assign gap     = good && !is_idle && d != '0 && !d[SEQ_BITS-1];

  assign fifo_valid   = deliver;
  assign fifo_fb      = '{ftype: in_flit.ftype, body: in_flit.body};
  assign overflow_err = deliver && !fifo_ready;

  // ------------------------------------------------------------ NAK
  logic nak_new, nak_resend, nak_load, nak_free;
  assign nak_free   = !nak_valid || nak_ready;
  assign nak_new    = (bad || gap) && !nak_pending_q;
  assign nak_resend = nak_pending_q && !deliver && nak_timer_q == RW'(NAK_RESEND - 1);
  assign nak_load   = (nak_new || nak_resend) && nak_free;

  // ------------------------------------------------------------ ACK
  logic [AW:0] unacked_n;
  logic        ack_free, ack_load;
  assign unacked_n = {1'b0, unacked_q} + (AW+1)'(deliver);
  assign ack_free  = !ack_valid || ack_ready;
  assign ack_load  = ack_free && unacked_n != '0 &&
                     (unacked_n >= (AW+1)'(ACK_FLITS) || (!deliver && idle_q >= IDW'(ACK_IDLE)));

  // ------------------------------------------------------------ NAK density
  logic          win_end;
  logic [LW-1:0] win_base;
  logic          density_hit;
  assign win_end     = in_valid && win_q == WW'(NAK_WIN_FLITS - 1);
  assign win_base    = win_end ? '0 : win_naks_q;
  assign density_hit = nak_load && win_naks_q == LW'(NAK_WIN_LIMIT - 1) && !win_end;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      expected_q    <= '0;
      nak_pending_q <= 1'b0;
      nak_timer_q   <= '0;
      nak_valid     <= 1'b0;
      nak_msg       <= '0;
      unacked_q     <= '0;
      idle_q        <= '0;
      ack_valid     <= 1'b0;
      ack_msg       <= '0;
      win_q         <= '0;
      win_naks_q    <= '0;
      retrain_req   <= 1'b0;
      stats         <= '0;
    end else begin
      if (deliver) expected_q <= expected_q + 1'b1;

      // NAK request (held until the sideband mux grants it)
      if (deliver)      nak_pending_q <= 1'b0;
      else if (nak_new) nak_pending_q <= 1'b1;
      if (nak_load) begin
        nak_valid <= 1'b1;
        nak_msg   <= sb_make(SB_NAK, 40'(expected_q));
      end else if (nak_ready) begin
        nak_valid <= 1'b0;
      end
      if (deliver || nak_load || !nak_pending_q) nak_timer_q <= '0;
      else if (nak_timer_q != RW'(NAK_RESEND - 1)) nak_timer_q <= nak_timer_q + 1'b1;

      // ACK request (cumulative, coalesced)
      if (ack_load) begin
        ack_valid <= 1'b1;
        ack_msg   <= sb_make(SB_ACK, 40'(seq_t'(expected_q + seq_t'(deliver) - 1'b1)));
        unacked_q <= '0;
      end else begin
        if (ack_ready) ack_valid <= 1'b0;
        unacked_q <= (unacked_n > (AW+1)'(ACK_FLITS)) ? AW'(ACK_FLITS) : AW'(unacked_n);
      end
      if (deliver)                     idle_q <= '0;
      else if (idle_q != IDW'(ACK_IDLE)) idle_q <= idle_q + 1'b1;

      // NAK-density window over received flits
      if (in_valid) win_q <= win_end ? '0 : win_q + 1'b1;
      if (nak_load && win_base != LW'(NAK_WIN_LIMIT)) win_naks_q <= win_base + 1'b1;
      else                                            win_naks_q <= win_base;
      retrain_req <= density_hit;

      // statistics
      stats.flits_ok     <= sat_inc(stats.flits_ok,     deliver);
      stats.crc_errors   <= sat_inc(stats.crc_errors,   bad);
      stats.seq_gaps     <= sat_inc(stats.seq_gaps,     gap);
      stats.duplicates   <= sat_inc(stats.duplicates,   dup);
      stats.naks_sent    <= sat_inc(stats.naks_sent,    nak_load);
      stats.nak_resends  <= sat_inc(stats.nak_resends,  nak_load && !nak_new);
      stats.acks_sent    <= sat_inc(stats.acks_sent,    ack_load);
      stats.retrain_reqs <= sat_inc(stats.retrain_reqs, density_hit);
    end
  end

  assign retrain_reason = RR_CRC_BURST;
endmodule
