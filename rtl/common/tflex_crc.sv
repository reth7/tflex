// =============================================================================
// tflex_crc -- combinational CRC over DATA_W bits, MSB first (docs/protocol.md
// section 2). Not reflected, no final XOR. The bit-serial loop below has only
// constant shifts, ANDs with the constant POLY and XORs (no branches), so
// synthesis folds it into one XOR matrix derived from POLY at elaboration
// time; nothing iterates in hardware.
// Golden model: python/tflex/protocol/crc.py.
// =============================================================================
module tflex_crc #(
  parameter int                DATA_W = 240,
  parameter int                CRC_W  = 16,
  parameter logic [CRC_W-1:0]  POLY   = 16'h1021,
  parameter logic [CRC_W-1:0]  INIT   = 16'hFFFF
) (
  input  logic [DATA_W-1:0] data,
  output logic [CRC_W-1:0]  crc
);
  always_comb begin
    crc = INIT;
    for (int i = DATA_W - 1; i >= 0; i--)
      crc = {crc[CRC_W-2:0], 1'b0} ^ (POLY & {CRC_W{crc[CRC_W-1] ^ data[i]}});
  end
endmodule
