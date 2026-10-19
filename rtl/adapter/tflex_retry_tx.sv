// =============================================================================
// tflex_retry_tx -- link-layer transmitter with go-back-N retry
// (docs/protocol.md section 4.1). Replaces the Milestone 1 tflex_adapter_tx.
//
// New flits (from the TX async FIFO) get seq = next_seq, a CRC over flit bits
// 255:16 and a slot in the replay buffer (indexed by seq mod RETRY_DEPTH).
// A new flit is sent only when
//   - a credit is available (one credit = one RX FIFO slot; consumed on the
//     first transmission only, never by replays), and
//   - next_seq - oldest_unacked < RETRY_DEPTH (window rule).
// Sideband input:
//   ACK(s)    cumulative: frees every flit up to and including s
//   NAK(e)    go-back-N: replay e .. next_seq-1 with flags.replay = 1, then
//             resume new traffic. The receiver NAKs only its next expected
//             sequence, so NAK(e) also acknowledges everything before e.
//             The (MAX_RETRY+1)-th NAK of the same e raises retrain_req
//             (reason RR_CRC_BURST) once.
//   CREDIT(n) returns n credits
// Replay timer: flits outstanding and no ACK/NAK for REPLAY_TIMEOUT cycles ->
// replay from the oldest unACKed flit (never expected with the reliable
// sideband; counted in stats.replay_timeouts).
//
// The output is one registered valid/ready stage (one link cycle of latency).
// RETRY_DEPTH: power of two, 2 .. 2^(SEQ_BITS-1), so sequence wrap-around is
// unambiguous.
// =============================================================================
module tflex_retry_tx
  import tflex_pkg::*;
#(
  parameter int  RETRY_DEPTH    = 64,
  parameter int  CREDITS        = 64,      // = receiver RX FIFO depth
  parameter int  MAX_RETRY      = 3,
  parameter int  REPLAY_TIMEOUT = 256,
  localparam int CW             = $clog2(CREDITS + 1),
  localparam int IW             = $clog2(RETRY_DEPTH),
  localparam int TW             = $clog2(REPLAY_TIMEOUT + 1),
  localparam int NW             = $clog2(MAX_RETRY + 2)
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            enable,          // link up (tied high until the LTSM, M4)
  // from TX FIFO (read side)
  input  logic            in_valid,
  output logic            in_ready,
  input  flit_body_t      in_fb,
  // sideband messages from the receiver (ACK / NAK / CREDIT)
  input  logic            sb_valid,
  input  sb_msg_t         sb_msg,
  // to PHY
  output logic            out_valid,
  input  logic            out_ready,
  output flit_t           out_flit,
  // status
  output logic [CW-1:0]   credits,
  output logic            retrain_req,     // one-cycle pulse
  output retrain_reason_e retrain_reason,
  output retry_tx_stats_t stats
);
  typedef logic [SEQ_BITS-1:0] seq_t;
  localparam int COV_W = FLIT_BITS - CRC_BITS;

  flit_body_t    buf_q [RETRY_DEPTH];
  seq_t          next_seq, send_ptr, oldest;
  logic [CW-1:0] credits_q;
  logic [TW-1:0] timer_q;
  seq_t          nak_seq_q;
  logic          nak_have_q;
  logic [NW-1:0] nak_cnt_q;

  // ------------------------------------------------------------ send side
  seq_t       outstanding;
  logic       replaying, slot_free, win_ok, send_new, send_replay, send;
  flit_body_t send_fb;
  logic [COV_W-1:0]    cov;
  logic [CRC_BITS-1:0] crc;

  assign outstanding = next_seq - oldest;
  assign replaying   = send_ptr != next_seq;
  assign slot_free   = !out_valid || out_ready;
  assign win_ok      = outstanding < seq_t'(RETRY_DEPTH);
  assign in_ready    = enable && slot_free && !replaying && credits_q != '0 && win_ok;
  assign send_new    = in_valid && in_ready;
  assign send_replay = enable && slot_free && replaying;
  assign send        = send_new || send_replay;
  assign send_fb     = send_replay ? buf_q[send_ptr[IW-1:0]] : in_fb;
  // covered bits 255:16 = {ftype, seq, flags.replay, flags.rsvd, body}
  assign cov         = {send_fb.ftype, send_ptr, send_replay, 4'b0, send_fb.body};

  tflex_crc #(.DATA_W(COV_W), .CRC_W(CRC_BITS), .POLY(CRC_POLY), .INIT(CRC_INIT)) u_crc (
    .data(cov), .crc
  );

  // ------------------------------------------------------------ sideband side
  seq_t sb_seq, adv_ack, adv_nak;
  logic is_ack, is_nak, is_credit, ack_ok, nak_ok, timeout;

  assign sb_seq    = sb_msg.arg[SEQ_BITS-1:0];
  assign is_ack    = sb_valid && sb_msg.op == SB_ACK;
  assign is_nak    = sb_valid && sb_msg.op == SB_NAK;
  assign is_credit = sb_valid && sb_msg.op == SB_CREDIT;
  assign adv_ack   = sb_seq + 1'b1 - oldest;            // flits newly acknowledged
  assign adv_nak   = sb_seq - oldest;
  assign ack_ok    = is_ack && adv_ack != '0 && adv_ack <= outstanding;
  assign nak_ok    = is_nak && adv_nak <= outstanding;
  assign timeout   = outstanding != '0 && !is_ack && !is_nak && timer_q == TW'(REPLAY_TIMEOUT - 1);

  // ------------------------------------------------------------ next state
  seq_t          sp_n, old_n;
  logic [CW-1:0] cr_n;
  logic          nak_repeat, escalate;

  always_comb begin
    sp_n  = send ? send_ptr + 1'b1 : send_ptr;
    old_n = oldest;
    cr_n  = send_new ? credits_q - 1'b1 : credits_q;
    if (ack_ok) begin
      old_n = sb_seq + 1'b1;
      if (seq_t'(sp_n - oldest) < adv_ack) sp_n = old_n;   // pending replay already acknowledged
    end
    if (nak_ok) begin                                      // go-back-N from the NAKed flit
      old_n = sb_seq;
      sp_n  = sb_seq;
    end
    if (is_credit) cr_n = cr_n + CW'(sb_msg.arg[7:0]);
    if (timeout)   sp_n = old_n;
  end

  assign nak_repeat = nak_ok && nak_have_q && sb_seq == nak_seq_q;
  assign escalate   = nak_repeat && nak_cnt_q == NW'(MAX_RETRY);   // (MAX_RETRY+1)-th NAK of e

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      next_seq    <= '0;
      send_ptr    <= '0;
      oldest      <= '0;
      credits_q   <= CW'(CREDITS);
      timer_q     <= '0;
      nak_seq_q   <= '0;
      nak_have_q  <= 1'b0;
      nak_cnt_q   <= '0;
      out_valid   <= 1'b0;
      out_flit    <= '0;
      retrain_req <= 1'b0;
      stats       <= '0;
    end else begin
      if (send) begin
        out_valid <= 1'b1;
        out_flit  <= {cov, crc};
      end else if (out_ready) begin
        out_valid <= 1'b0;
      end
      if (send_new) next_seq <= next_seq + 1'b1;
      send_ptr  <= sp_n;
      oldest    <= old_n;
      credits_q <= cr_n;
      timer_q   <= (outstanding == '0 || is_ack || is_nak || timeout) ? '0 : timer_q + 1'b1;

      // per-sequence NAK count -> MAX_RETRY escalation (once per stuck flit)
      retrain_req <= escalate;
      if (nak_repeat) begin
        if (nak_cnt_q != '1) nak_cnt_q <= nak_cnt_q + 1'b1;
      end else if (nak_ok) begin
        nak_have_q <= 1'b1;
        nak_seq_q  <= sb_seq;
        nak_cnt_q  <= NW'(1);
      end else if (ack_ok && nak_have_q && seq_t'(nak_seq_q - oldest) < adv_ack) begin
        nak_have_q <= 1'b0;                                  // NAKed flit acknowledged
      end

      // statistics
      stats.flits_new         <= sat_inc(stats.flits_new,         send_new);
      stats.flits_replayed    <= sat_inc(stats.flits_replayed,    send_replay);
      stats.stall_no_credit   <= sat_inc(stats.stall_no_credit,
                                         enable && in_valid && !replaying && credits_q == '0);
      stats.stall_window_full <= sat_inc(stats.stall_window_full,
                                         enable && in_valid && !replaying && credits_q != '0 && !win_ok);
      stats.replay_events     <= sat_inc(stats.replay_events,     nak_ok);
      stats.replay_timeouts   <= sat_inc(stats.replay_timeouts,   timeout);
      stats.retrain_reqs      <= sat_inc(stats.retrain_reqs,      escalate);
    end
  end

  // Replay buffer: data only, no reset (a slot is read only after it was written).
  always_ff @(posedge clk) begin
    if (send_new) buf_q[next_seq[IW-1:0]] <= in_fb;
  end

  assign credits        = credits_q;
  assign retrain_reason = RR_CRC_BURST;
endmodule
