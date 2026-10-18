"""CRC-16 golden model (docs/protocol.md section 2).

Polynomial 0x1021, init 0xFFFF, not reflected, no final XOR, processed
MSB-first. For a flit the covered bits are 255:16 (240 bits) and the result
sits in bits 15:0.
"""

POLY = 0x1021
INIT = 0xFFFF
WIDTH = 16
FLIT_BITS = 256
COVERED_BITS = FLIT_BITS - WIDTH   # 240


def crc_bits(value: int, nbits: int, poly: int = POLY, init: int = INIT,
             width: int = WIDTH) -> int:
    """CRC of the `nbits`-bit integer `value`, most significant bit first."""
    mask = (1 << width) - 1
    top = 1 << (width - 1)
    c = init
    for i in range(nbits - 1, -1, -1):
        fb = ((c & top) != 0) ^ ((value >> i) & 1)
        c = (c << 1) & mask
        if fb:
            c ^= poly
    return c


def flit_crc(covered: int) -> int:
    """CRC over the 240 covered bits of a flit (flit bits 255:16)."""
    return crc_bits(covered, COVERED_BITS)


def flit_with_crc(covered: int) -> int:
    """Full 256-bit flit: covered bits followed by their CRC."""
    return (covered << WIDTH) | flit_crc(covered)


def flit_crc_ok(flit: int) -> bool:
    return flit_crc(flit >> WIDTH) == (flit & ((1 << WIDTH) - 1))
