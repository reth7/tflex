"""L0: CRC-16 golden model (docs/protocol.md section 2)."""
import random

from tflex.protocol.crc import COVERED_BITS, crc_bits, flit_crc, flit_crc_ok, flit_with_crc
from tflex.protocol.packet import flit_covered


def test_reference_vectors():
    # protocol.md section 2: 240 zero bits -> 0x2A45; seq = 0x5A, rest zero -> 0xB7C3
    assert flit_crc(0) == 0x2A45
    assert flit_crc(flit_covered(0, 0x5A, 0, 0)) == 0xB7C3


def test_standard_check_value():
    # CRC-16/CCITT-FALSE (same poly/init/no reflection/no xorout) check value
    data = int.from_bytes(b"123456789", "big")
    assert crc_bits(data, 72) == 0x29B1


def test_linearity():
    # CRC with init is affine: crc(a^b) == crc(a) ^ crc(b) ^ crc(0)
    rng = random.Random(1)
    for _ in range(200):
        a, b = rng.getrandbits(COVERED_BITS), rng.getrandbits(COVERED_BITS)
        assert flit_crc(a ^ b) == flit_crc(a) ^ flit_crc(b) ^ flit_crc(0)


def test_all_single_bit_errors_detected():
    rng = random.Random(2)
    for _ in range(4):
        f = flit_with_crc(rng.getrandbits(COVERED_BITS))
        assert flit_crc_ok(f)
        for i in range(256):            # covered bits and CRC bits
            assert not flit_crc_ok(f ^ (1 << i))


def test_all_double_bit_errors_detected():
    f = flit_with_crc(random.Random(3).getrandbits(COVERED_BITS))
    for i in range(256):
        for j in range(i + 1, 256):
            assert not flit_crc_ok(f ^ (1 << i) ^ (1 << j))


def test_bursts_up_to_16_detected():
    rng = random.Random(4)
    f = flit_with_crc(rng.getrandbits(COVERED_BITS))
    for length in range(1, 17):
        for start in range(0, 256 - length + 1):
            inner = rng.getrandbits(max(length - 2, 0)) if length > 2 else 0
            pattern = 1 | (inner << 1) | (1 << (length - 1))   # first and last bit set
            assert not flit_crc_ok(f ^ (pattern << start))
