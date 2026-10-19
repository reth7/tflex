// =============================================================================
// tflex_d2d_link_simplex -- one direction of a D2D link, source to sink,
// across three clock domains, with CRC + go-back-N retry (Milestone 2).
//
//  clk_src | clk_link                                                   | clk_dst
//  in ---> [TX async FIFO] -> retry_tx -> phy_tx -> channel -> phy_rx -> retry_rx
//          |                  ^ ACK/NAK/CREDIT   (fault injector)          |  |
//          |                  sideband <- sb_mux <- NAK, ACK --------------+  |
//          |                                    <- credit_return <-- [RX async FIFO] ---> out
//
// Both link endpoints share clk_link (forwarded-clock abstraction, see
// docs/architecture.md section 3). CDC happens only in the two async FIFOs.
// Sideband priority: NAK > ACK > CREDIT (training messages join in M4).
// Timer defaults follow configs/default.yaml: NAK resend = 2 x (channel +
// sideband latency) + 32 link cycles, replay timeout = 4 x NAK resend.
// =============================================================================
module tflex_d2d_link_simplex
  import tflex_pkg::*;
#(
  parameter int  TX_FIFO_DEPTH   = 64,
  parameter int  RX_FIFO_DEPTH   = 64,     // = credits
  parameter int  CHANNEL_LATENCY = 8,
  parameter int  SB_LATENCY      = 8,
  parameter int  RETRY_DEPTH     = 64,
  parameter int  MAX_RETRY       = 3,
  parameter int  NAK_RESEND      = 2 * (CHANNEL_LATENCY + SB_LATENCY) + 32,
  parameter int  REPLAY_TIMEOUT  = 4 * NAK_RESEND,
  parameter int  FI_CMDS         = 4,
  localparam int RX_PTR_W        = $clog2(RX_FIFO_DEPTH) + 1,
  localparam int TX_PTR_W        = $clog2(TX_FIFO_DEPTH) + 1,
  localparam int FI_SW           = (FI_CMDS > 1) ? $clog2(FI_CMDS) : 1
) (
  // source domain
  input  logic            clk_src,
  input  logic            rst_src_n,
  input  logic            in_valid,
  output logic            in_ready,
  input  flit_body_t      in_fb,
  // link domain
  input  logic            clk_link,
  input  logic            rst_link_n,
  // destination domain
  input  logic            clk_dst,
  input  logic            rst_dst_n,
  output logic            out_valid,
  input  logic            out_ready,
  output flit_body_t      out_fb,
  // link-domain fault injection (channel)
  input  logic            fi_cmd_valid,
  input  logic [FI_SW-1:0] fi_cmd_slot,
  input  fault_cmd_t      fi_cmd,
  output logic [31:0]     fi_cycle,
  output logic [31:0]     fi_corrupted,
  // link-domain status
  output logic [RX_PTR_W-1:0] credits,
  output retry_tx_stats_t tx_stats,
  output retry_rx_stats_t rx_stats,
  output logic            tx_retrain_req,
  output logic            rx_retrain_req,
  output logic            overflow_err
);
  localparam int FBW = $bits(flit_body_t);
  localparam int SBW = $bits(sb_msg_t);

  // ---------------------------------------------------------- TX async FIFO
  logic             txf_r_valid, txf_r_ready;
  logic [FBW-1:0]   txf_r_data;
  logic [TX_PTR_W-1:0] txf_w_count, txf_w_rptr, txf_r_count;

  tflex_async_fifo #(.WIDTH(FBW), .DEPTH(TX_FIFO_DEPTH)) u_tx_fifo (
    .wclk(clk_src),  .wrst_n(rst_src_n),
    .w_valid(in_valid), .w_ready(in_ready), .w_data(in_fb),
    .w_count(txf_w_count), .w_rptr_bin(txf_w_rptr),
    .rclk(clk_link), .rrst_n(rst_link_n),
    .r_valid(txf_r_valid), .r_ready(txf_r_ready), .r_data(txf_r_data),
    .r_count(txf_r_count)
  );

  // ---------------------------------------------------------- retry TX
  logic            sb_rx_valid;
  logic [SBW-1:0]  sb_rx_msg;
  logic            rtx_valid;
  flit_t           rtx_flit;
  retrain_reason_e tx_retrain_reason, rx_retrain_reason;

  tflex_retry_tx #(.RETRY_DEPTH(RETRY_DEPTH), .CREDITS(RX_FIFO_DEPTH), .MAX_RETRY(MAX_RETRY),
                   .REPLAY_TIMEOUT(REPLAY_TIMEOUT)) u_retry_tx (
    .clk(clk_link), .rst_n(rst_link_n), .enable(1'b1),
    .in_valid(txf_r_valid), .in_ready(txf_r_ready), .in_fb(flit_body_t'(txf_r_data)),
    .sb_valid(sb_rx_valid), .sb_msg(sb_msg_t'(sb_rx_msg)),
    .out_valid(rtx_valid), .out_ready(1'b1), .out_flit(rtx_flit),
    .credits, .retrain_req(tx_retrain_req), .retrain_reason(tx_retrain_reason),
    .stats(tx_stats)
  );

  // ---------------------------------------------------------- PHY + channel
  logic                            ptx_valid, ch_valid, prx_valid;
  logic [PHYS_LANES*LANE_BITS-1:0] ptx_data, ch_data;
  flit_t                           prx_flit;

  tflex_phy_tx u_phy_tx (
    .clk(clk_link), .rst_n(rst_link_n),
    .in_valid(rtx_valid), .in_flit(rtx_flit),
    .lane_valid(ptx_valid), .lane_data(ptx_data)
  );

  tflex_d2d_channel #(.LATENCY(CHANNEL_LATENCY), .FI_CMDS(FI_CMDS)) u_channel (
    .clk(clk_link), .rst_n(rst_link_n),
    .tx_valid(ptx_valid), .tx_data(ptx_data),
    .rx_valid(ch_valid),  .rx_data(ch_data),
    .fi_cmd_valid, .fi_cmd_slot, .fi_cmd, .fi_cycle, .fi_corrupted
  );

  tflex_phy_rx u_phy_rx (
    .clk(clk_link), .rst_n(rst_link_n),
    .lane_valid(ch_valid), .lane_data(ch_data),
    .out_valid(prx_valid), .out_flit(prx_flit)
  );

  // ---------------------------------------------------------- retry RX
  logic       rxf_w_valid, rxf_w_ready;
  flit_body_t rxf_w_fb;
  logic [RX_PTR_W-1:0] rxf_w_count, rxf_w_rptr, rxf_r_count;
  logic [FBW-1:0]      rxf_r_data;
  logic       ack_valid, ack_ready, nak_valid, nak_ready;
  sb_msg_t    ack_msg, nak_msg;

  tflex_retry_rx #(.NAK_RESEND(NAK_RESEND)) u_retry_rx (
    .clk(clk_link), .rst_n(rst_link_n),
    .in_valid(prx_valid), .in_flit(prx_flit),
    .fifo_valid(rxf_w_valid), .fifo_ready(rxf_w_ready), .fifo_fb(rxf_w_fb),
    .ack_valid, .ack_ready, .ack_msg, .nak_valid, .nak_ready, .nak_msg,
    .overflow_err, .retrain_req(rx_retrain_req), .retrain_reason(rx_retrain_reason),
    .stats(rx_stats)
  );

  // ---------------------------------------------------------- RX async FIFO
  tflex_async_fifo #(.WIDTH(FBW), .DEPTH(RX_FIFO_DEPTH)) u_rx_fifo (
    .wclk(clk_link), .wrst_n(rst_link_n),
    .w_valid(rxf_w_valid), .w_ready(rxf_w_ready), .w_data(rxf_w_fb),
    .w_count(rxf_w_count), .w_rptr_bin(rxf_w_rptr),
    .rclk(clk_dst), .rrst_n(rst_dst_n),
    .r_valid(out_valid), .r_ready(out_ready), .r_data(rxf_r_data),
    .r_count(rxf_r_count)
  );
  assign out_fb = flit_body_t'(rxf_r_data);

  // ---------------------------------------------------------- sideband (RX -> TX)
  logic    crr_valid, crr_ready, sb_tx_valid;
  sb_msg_t crr_msg, sb_tx_msg;

  tflex_credit_return #(.PTR_W(RX_PTR_W)) u_credit_return (
    .clk(clk_link), .rst_n(rst_link_n),
    .rptr_bin(rxf_w_rptr), .msg_valid(crr_valid), .msg_ready(crr_ready), .msg(crr_msg)
  );

  tflex_sb_mux #(.N(3)) u_sb_mux (
    .req_valid({crr_valid, ack_valid, nak_valid}),
    .req_ready({crr_ready, ack_ready, nak_ready}),
    .req_msg  ({crr_msg,   ack_msg,   nak_msg}),
    .out_valid(sb_tx_valid), .out_msg(sb_tx_msg)
  );

  tflex_sideband_channel #(.WIDTH(SBW), .LATENCY(SB_LATENCY)) u_sideband (
    .clk(clk_link), .rst_n(rst_link_n),
    .tx_valid(sb_tx_valid), .tx_msg(sb_tx_msg),
    .rx_valid(sb_rx_valid), .rx_msg(sb_rx_msg)
  );

  // Occupancy counters and retrain reasons are observed by the testbench only;
  // the retrain requests are consumed by the LTSM in Milestone 4.
  logic unused_counts;
  assign unused_counts = ^{txf_w_count, txf_w_rptr, txf_r_count, rxf_w_count, rxf_r_count,
                           tx_retrain_reason, rx_retrain_reason};
endmodule
