// =============================================================================
// tflex_async_fifo_sva -- checks for tflex_async_fifo (bound in simulation).
//
// Occupancy is computed from the TRUE binary pointers of both domains (a
// simulation-only view that no hardware can have); it must always lie in
// [0, DEPTH]. Because the pointer difference is taken modulo 2^(ADDR_W+1), a
// negative occupancy (underflow) also shows up as a value > DEPTH.
// =============================================================================
module tflex_async_fifo_sva #(
  parameter int DEPTH  = 16,
  parameter int ADDR_W = 4,
  parameter int WIDTH  = 8
) (
  input logic              wclk, wrst_n, rclk, rrst_n,
  input logic              w_valid, w_ready, r_valid, r_ready,
  input logic [WIDTH-1:0]  w_data, r_data,
  input logic [ADDR_W:0]   wbin_q, wgray_q, rbin_q, rgray_q, w_count
);
  logic [ADDR_W:0] occ;
  assign occ = wbin_q - rbin_q;

  // -- no overflow / no underflow (true occupancy), sampled in both domains
  a_occ_w: assert property (@(posedge wclk) disable iff (!wrst_n || !rrst_n) occ <= (ADDR_W+1)'(DEPTH))
    else $error("async_fifo: occupancy %0d outside [0,%0d] (overflow/underflow)", occ, DEPTH);
  a_occ_r: assert property (@(posedge rclk) disable iff (!wrst_n || !rrst_n) occ <= (ADDR_W+1)'(DEPTH))
    else $error("async_fifo: occupancy %0d outside [0,%0d] (overflow/underflow)", occ, DEPTH);

  // -- a write is only accepted when the writer's view says there is space
  a_push_space: assert property (@(posedge wclk) disable iff (!wrst_n)
                                 (w_valid && w_ready) |-> (w_count < (ADDR_W+1)'(DEPTH)))
    else $error("async_fifo: write accepted with w_count=%0d", w_count);

  // -- a read is only possible when the FIFO truly holds data
  a_pop_data: assert property (@(posedge rclk) disable iff (!wrst_n || !rrst_n)
                               (r_valid && r_ready) |-> (occ != '0))
    else $error("async_fifo: read from empty FIFO (underflow)");

  // -- Gray pointers change by at most one bit per clock (CDC safety)
  a_wgray_1bit: assert property (@(posedge wclk) disable iff (!wrst_n)
                                 $countones(wgray_q ^ $past(wgray_q)) <= 1)
    else $error("async_fifo: write Gray pointer changed by more than one bit");
  a_rgray_1bit: assert property (@(posedge rclk) disable iff (!rrst_n)
                                 $countones(rgray_q ^ $past(rgray_q)) <= 1)
    else $error("async_fifo: read Gray pointer changed by more than one bit");

  // -- Gray/binary pointers consistent
  a_wgray_ok: assert property (@(posedge wclk) disable iff (!wrst_n) wgray_q == (wbin_q ^ (wbin_q >> 1)))
    else $error("async_fifo: write Gray pointer inconsistent with binary");
  a_rgray_ok: assert property (@(posedge rclk) disable iff (!rrst_n) rgray_q == (rbin_q ^ (rbin_q >> 1)))
    else $error("async_fifo: read Gray pointer inconsistent with binary");

  // -- reset behaviour (from the second clock of a reset; see tflex_stream_sva)
  logic w_in_rst_q = 1'b0, r_in_rst_q = 1'b0;
  always @(posedge wclk) w_in_rst_q <= !wrst_n;
  always @(posedge rclk) r_in_rst_q <= !rrst_n;

  a_rst_w: assert property (@(posedge wclk) (!wrst_n && w_in_rst_q) |-> (wbin_q == '0 && wgray_q == '0 && !w_ready))
    else $error("async_fifo: write side not in reset state during reset");
  a_rst_r: assert property (@(posedge rclk) (!rrst_n && r_in_rst_q) |-> (rbin_q == '0 && rgray_q == '0 && !r_valid))
    else $error("async_fifo: read side not in reset state during reset");
endmodule

bind tflex_async_fifo tflex_async_fifo_sva #(.DEPTH(DEPTH), .ADDR_W(ADDR_W), .WIDTH(WIDTH)) u_fifo_sva (
  .wclk, .wrst_n, .rclk, .rrst_n, .w_valid, .w_ready, .r_valid, .r_ready,
  .w_data, .r_data, .wbin_q, .wgray_q, .rbin_q, .rgray_q, .w_count
);

bind tflex_async_fifo tflex_stream_sva #(.WIDTH(WIDTH), .NAME("fifo_w")) u_w_stream_sva (
  .clk(wclk), .rst_n(wrst_n), .valid(w_valid), .ready(w_ready), .data(w_data)
);

bind tflex_async_fifo tflex_stream_sva #(.WIDTH(WIDTH), .NAME("fifo_r")) u_r_stream_sva (
  .clk(rclk), .rst_n(rrst_n), .valid(r_valid), .ready(r_ready), .data(r_data)
);
