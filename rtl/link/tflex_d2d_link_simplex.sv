// =============================================================================
// tflex_d2d_link_simplex -- one direction of a D2D link, source to sink,
// across three clock domains (Milestone 1).
//
//  clk_src | clk_link                                                  | clk_dst
//  in ---> [TX async FIFO] -> adapter_tx -> phy_tx -> channel -> phy_rx
//          |                  ^ credits                           |
//          |                  sideband <- credit_return <---------+-> adapter_rx
//          |                                                  [RX async FIFO] ---> out
//
// Both link endpoints share clk_link (forwarded-clock abstraction, see
// docs/architecture.md section 3). CDC happens only in the two async FIFOs.
// =============================================================================
module tflex_d2d_link_simplex
  import tflex_pkg::*;
#(
  parameter int TX_FIFO_DEPTH   = 64,
  parameter int RX_FIFO_DEPTH   = 64,     // = credits
  parameter int CHANNEL_LATENCY = 8,
  parameter int SB_LATENCY      = 8,
  localparam int RX_PTR_W       = $clog2(RX_FIFO_DEPTH) + 1,
  localparam int TX_PTR_W       = $clog2(TX_FIFO_DEPTH) + 1
) (
  // source domain
  input  logic        clk_src,
  input  logic        rst_src_n,
  input  logic        in_valid,
  output logic        in_ready,
  input  flit_body_t  in_fb,
  // link domain
  input  logic        clk_link,
  input  logic        rst_link_n,
  // destination domain
  input  logic        clk_dst,
  input  logic        rst_dst_n,
  output logic        out_valid,
  input  logic        out_ready,
  output flit_body_t  out_fb,
  // link-domain status
  output logic [RX_PTR_W-1:0] credits,
  output logic [31:0] stat_flits_sent,
  output logic [31:0] stat_flits_rcvd,
  output logic [31:0] stat_stall_no_credit,
  output logic        overflow_err
);
  localparam int FBW = $bits(flit_body_t);

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

  // ---------------------------------------------------------- adapter TX
  logic                cr_valid;
  logic [RX_PTR_W-1:0] cr_count;
  logic                atx_valid;
  flit_t               atx_flit;

  tflex_adapter_tx #(.CREDITS(RX_FIFO_DEPTH)) u_adapter_tx (
    .clk(clk_link), .rst_n(rst_link_n), .enable(1'b1),
    .in_valid(txf_r_valid), .in_ready(txf_r_ready), .in_fb(flit_body_t'(txf_r_data)),
    .cr_valid, .cr_count,
    .out_valid(atx_valid), .out_flit(atx_flit),
    .credits, .stat_flits_sent, .stat_stall_no_credit
  );

  // ---------------------------------------------------------- PHY + channel
  logic                            ptx_valid, ch_valid, prx_valid;
  logic [PHYS_LANES*LANE_BITS-1:0] ptx_data, ch_data;
  flit_t                           prx_flit;

  tflex_phy_tx u_phy_tx (
    .clk(clk_link), .rst_n(rst_link_n),
    .in_valid(atx_valid), .in_flit(atx_flit),
    .lane_valid(ptx_valid), .lane_data(ptx_data)
  );

  tflex_d2d_channel #(.LATENCY(CHANNEL_LATENCY)) u_channel (
    .clk(clk_link), .rst_n(rst_link_n),
    .tx_valid(ptx_valid), .tx_data(ptx_data),
    .rx_valid(ch_valid),  .rx_data(ch_data)
  );

  tflex_phy_rx u_phy_rx (
    .clk(clk_link), .rst_n(rst_link_n),
    .lane_valid(ch_valid), .lane_data(ch_data),
    .out_valid(prx_valid), .out_flit(prx_flit)
  );

  // ---------------------------------------------------------- adapter RX
  logic       rxf_w_valid, rxf_w_ready;
  flit_body_t rxf_w_fb;
  logic [RX_PTR_W-1:0] rxf_w_count, rxf_w_rptr, rxf_r_count;
  logic [FBW-1:0]      rxf_r_data;

  tflex_adapter_rx u_adapter_rx (
    .clk(clk_link), .rst_n(rst_link_n),
    .in_valid(prx_valid), .in_flit(prx_flit),
    .fifo_valid(rxf_w_valid), .fifo_ready(rxf_w_ready), .fifo_fb(rxf_w_fb),
    .overflow_err, .stat_flits_rcvd
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

  // ---------------------------------------------------------- credit return
  logic                crr_valid;
  logic [RX_PTR_W-1:0] crr_count;

  tflex_credit_return #(.PTR_W(RX_PTR_W)) u_credit_return (
    .clk(clk_link), .rst_n(rst_link_n),
    .rptr_bin(rxf_w_rptr), .msg_valid(crr_valid), .msg_count(crr_count)
  );

  tflex_sideband_channel #(.WIDTH(RX_PTR_W), .LATENCY(SB_LATENCY)) u_sideband (
    .clk(clk_link), .rst_n(rst_link_n),
    .tx_valid(crr_valid), .tx_msg(crr_count),
    .rx_valid(cr_valid),  .rx_msg(cr_count)
  );

  // Occupancy counters are observed by the testbench/assertions only.
  logic unused_counts;
  assign unused_counts = ^{txf_w_count, txf_w_rptr, txf_r_count, rxf_w_count, rxf_r_count};
endmodule
