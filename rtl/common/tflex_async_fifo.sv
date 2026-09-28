// =============================================================================
// tflex_async_fifo -- dual-clock FIFO with Gray-coded pointers.
//
// Classic structure (Cummings, SNUG 2002): binary + Gray pointers of
// ADDR_W+1 bits in each domain; the opposite domain's Gray pointer is brought
// across with a SYNC_STAGES flop synchronizer. Full/empty are computed from
// the synchronized (therefore stale) pointer, so they are conservative:
// the FIFO may report full/empty a few cycles longer than necessary, but it
// can never overflow or underflow.
//
// Interfaces are valid/ready: a write happens when w_valid && w_ready,
// a read when r_valid && r_ready. Read data is first-word-fall-through.
//
// Reset: both domains must be reset together (wrst_n and rrst_n asserted in
// overlapping windows); the system reset tree guarantees this. Resetting only
// one side while the other holds data is not supported.
//
// Also exported for the credit mechanism: w_rptr_bin, the read pointer as seen
// (synchronized) in the write domain, in binary.
// =============================================================================
module tflex_async_fifo #(
  parameter int WIDTH       = 8,
  parameter int DEPTH       = 16,   // power of two, >= 4
  parameter int SYNC_STAGES = 2,
  localparam int ADDR_W     = $clog2(DEPTH)
) (
  // write domain
  input  logic              wclk,
  input  logic              wrst_n,
  input  logic              w_valid,
  output logic              w_ready,
  input  logic [WIDTH-1:0]  w_data,
  output logic [ADDR_W:0]   w_count,     // occupancy as seen by the writer (>= true)
  output logic [ADDR_W:0]   w_rptr_bin,  // synchronized read pointer, binary
  // read domain
  input  logic              rclk,
  input  logic              rrst_n,
  output logic              r_valid,
  input  logic              r_ready,
  output logic [WIDTH-1:0]  r_data,
  output logic [ADDR_W:0]   r_count      // occupancy as seen by the reader (<= true)
);
  // ---------------------------------------------------------------- helpers
  function automatic logic [ADDR_W:0] bin2gray(logic [ADDR_W:0] b);
    return b ^ (b >> 1);
  endfunction

  function automatic logic [ADDR_W:0] gray2bin(logic [ADDR_W:0] g);
    logic [ADDR_W:0] b;
    b[ADDR_W] = g[ADDR_W];
    for (int i = ADDR_W - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  // ---------------------------------------------------------------- storage
  logic [WIDTH-1:0] mem [DEPTH];

  // ---------------------------------------------------------------- write side
  logic [ADDR_W:0] wbin_q, wgray_q, wbin_next;
  logic [ADDR_W:0] rgray_sync_w;         // read Gray pointer in write domain
  logic            wfull;
  logic            w_push;

  assign w_push    = w_valid && w_ready;
  assign wbin_next = wbin_q + (ADDR_W+1)'(w_push);

  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wbin_q  <= '0;
      wgray_q <= '0;
    end else begin
      wbin_q  <= wbin_next;
      wgray_q <= bin2gray(wbin_next);
    end
  end

  always_ff @(posedge wclk) begin
    if (w_push) mem[wbin_q[ADDR_W-1:0]] <= w_data;
  end

  tflex_sync_bits #(.WIDTH(ADDR_W+1), .STAGES(SYNC_STAGES)) u_sync_r2w (
    .clk(wclk), .rst_n(wrst_n), .d(rgray_q), .q(rgray_sync_w)
  );

  // Full when the pointers differ only in the MSB (binary view).
  assign w_rptr_bin = gray2bin(rgray_sync_w);
  assign wfull      = (wbin_q[ADDR_W] != w_rptr_bin[ADDR_W]) &&
                      (wbin_q[ADDR_W-1:0] == w_rptr_bin[ADDR_W-1:0]);
  assign w_ready    = !wfull && wrst_n;
  assign w_count    = wbin_q - w_rptr_bin;

  // ---------------------------------------------------------------- read side
  logic [ADDR_W:0] rbin_q, rgray_q, rbin_next;
  logic [ADDR_W:0] wgray_sync_r;         // write Gray pointer in read domain
  logic [ADDR_W:0] r_wptr_bin;
  logic            rempty;
  logic            r_pop;

  assign r_pop     = r_valid && r_ready;
  assign rbin_next = rbin_q + (ADDR_W+1)'(r_pop);

  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rbin_q  <= '0;
      rgray_q <= '0;
    end else begin
      rbin_q  <= rbin_next;
      rgray_q <= bin2gray(rbin_next);
    end
  end

  tflex_sync_bits #(.WIDTH(ADDR_W+1), .STAGES(SYNC_STAGES)) u_sync_w2r (
    .clk(rclk), .rst_n(rrst_n), .d(wgray_q), .q(wgray_sync_r)
  );

  assign r_wptr_bin = gray2bin(wgray_sync_r);
  assign rempty     = (r_wptr_bin == rbin_q);
  assign r_valid    = !rempty && rrst_n;
  assign r_data     = mem[rbin_q[ADDR_W-1:0]];
  assign r_count    = r_wptr_bin - rbin_q;

  // Elaboration checks
  initial begin
    if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "tflex_async_fifo: DEPTH (%0d) must be a power of two >= 4", DEPTH);
    if (SYNC_STAGES < 2)
      $fatal(1, "tflex_async_fifo: SYNC_STAGES must be >= 2");
  end
endmodule
