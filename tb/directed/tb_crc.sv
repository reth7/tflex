// =============================================================================
// tb_crc -- tflex_crc against the Python golden model and the CRC properties
// the protocol relies on (docs/protocol.md section 2, verification.md section 3).
//
// Plusargs: +VECTORS=<file> (from scripts/gen_crc_vectors.py)  +NVEC=<n expected>
//           +NBURST=<random bursts>   seeded with +verilator+seed+<n>
// Checks:
//   1. reference vectors 0x2A45 / 0xB7C3
//   2. every vector in the file matches the golden CRC
//   3. all 256 single-bit errors (covered bits and CRC field) of the first 16
//      file flits are detected
//   4. random bursts of length 1..16 (first and last bit set) anywhere in the
//      256-bit flit are detected
// =============================================================================
module tb_crc;
  import tflex_pkg::*;
  localparam int CW = FLIT_BITS - CRC_BITS;   // 240 covered bits

  logic [CW-1:0]       data;
  logic [CRC_BITS-1:0] crc;
  tflex_crc #(.DATA_W(CW), .CRC_W(CRC_BITS), .POLY(CRC_POLY), .INIT(CRC_INIT)) dut (.data, .crc);

  int unsigned errors = 0, nvec = 0, nvec_exp = 0, nsingle = 0, nburst = 0, nburst_req = 20000;
  logic [CW-1:0]       keep_d [16];
  logic [CRC_BITS-1:0] keep_c [16];

  // CRC of `d` through the DUT (combinational: settle, then read).
  task automatic dut_crc(input logic [CW-1:0] d, output logic [CRC_BITS-1:0] c);
    data = d;
    #1;
    c = crc;
  endtask

  // A received flit is accepted iff crc(covered) equals its CRC field.
  function automatic logic accepted(logic [FLIT_BITS-1:0] f, logic [CRC_BITS-1:0] c_of_cov);
    return c_of_cov == f[CRC_BITS-1:0];
  endfunction

  initial begin
    string               fname = "build/crc_vectors.txt";
    int                  fd, r;
    logic [CW-1:0]       d;
    logic [CRC_BITS-1:0] c, cexp;
    flit_t               f;

    void'($value$plusargs("VECTORS=%s", fname));
    void'($value$plusargs("NVEC=%d", nvec_exp));
    void'($value$plusargs("NBURST=%d", nburst_req));

    // 1. reference vectors
    dut_crc('0, c);
    if (c != 16'h2A45) begin $error("ref: zero flit crc %h, expected 2a45", c); errors++; end
    f = '0; f.seq = 8'h5A;
    dut_crc(f[FLIT_BITS-1:CRC_BITS], c);
    if (c != 16'hB7C3) begin $error("ref: seq=5A crc %h, expected b7c3", c); errors++; end

    // 2. golden vectors
    fd = $fopen(fname, "r");
    if (fd == 0) begin $error("cannot open %s", fname); errors++; end
    else begin
      while (!$feof(fd)) begin
        r = $fscanf(fd, "%h %h\n", d, cexp);
        if (r != 2) break;
        dut_crc(d, c);
        if (c != cexp) begin
          if (errors < 10) $error("vector %0d: crc %h, golden %h", nvec, c, cexp);
          errors++;
        end
        if (nvec < 16) begin keep_d[nvec] = d; keep_c[nvec] = cexp; end
        nvec++;
      end
      $fclose(fd);
    end
    if (nvec_exp != 0 && nvec != nvec_exp) begin $error("read %0d vectors, expected %0d", nvec, nvec_exp); errors++; end

    // 3. exhaustive single-bit errors on 16 flits
    for (int k = 0; k < 16 && k < int'(nvec); k++) begin
      for (int b = 0; b < FLIT_BITS; b++) begin
        logic [FLIT_BITS-1:0] fl;
        fl = {keep_d[k], keep_c[k]};
        fl[b] = ~fl[b];
        dut_crc(fl[FLIT_BITS-1:CRC_BITS], c);
        if (accepted(fl, c)) begin $error("single-bit error at bit %0d of flit %0d not detected", b, k); errors++; end
        nsingle++;
      end
    end

    // 4. random bursts <= 16 bits
    for (int n = 0; n < int'(nburst_req); n++) begin
      logic [FLIT_BITS-1:0] fl, pat;
      int unsigned len, start;
      dut_crc({$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom}, c);
      fl    = {data, c};                                   // a valid flit
      len   = 1 + ($urandom % 16);
      start = $urandom % (FLIT_BITS - len + 1);
      pat   = FLIT_BITS'({$urandom, $urandom}) & ((FLIT_BITS'(1) << len) - 1);
      pat[0] = 1'b1; pat[len-1] = 1'b1;                    // burst spans exactly len bits
      fl    = fl ^ (pat << start);
      dut_crc(fl[FLIT_BITS-1:CRC_BITS], c);
      if (accepted(fl, c)) begin $error("burst len %0d at %0d not detected", len, start); errors++; end
      nburst++;
    end

    $display("RESULT tb=crc vectors=%0d single_bit=%0d bursts=%0d errors=%0d %s",
             nvec, nsingle, nburst, errors, (errors == 0) ? "PASS" : "FAIL");
    if (errors != 0) $fatal(1, "tb_crc FAILED");
    $finish;
  end
endmodule
