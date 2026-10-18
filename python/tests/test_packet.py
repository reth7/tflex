"""L0: flit / packet golden model (docs/protocol.md sections 2-3)."""
import pytest

from tflex.protocol import packet as P


def test_wire_efficiency_table():
    # protocol.md section 3 table
    assert P.packet_flits(64) == 4 and round(100 * P.payload_efficiency(64), 1) == 50.0
    assert P.packet_flits(1024) == 38 and round(100 * P.payload_efficiency(1024), 1) == 84.2
    assert P.packet_flits(4096) == 148 and round(100 * P.payload_efficiency(4096), 1) == 86.5


@pytest.mark.parametrize("n,flits", [(0, 1), (1, 2), (27, 2), (28, 2), (29, 3), (56, 3),
                                     (57, 4), (256, 11), (1024, 38), (4096, 148), (65535, 2342)])
def test_flit_counts_match_m1_lengths(n, flits):
    # M1 single-test lengths; 65535 B = 2342 flits is quoted in m1_report.md
    assert P.packet_flits(n) == flits


def test_packetize_types_and_tail_padding():
    h = P.Header(ptype=P.PT_WR_REQ, len=57, tag=3, addr=0x1000_0000)
    fl = P.packetize(h)
    assert [t for t, _ in fl] == [P.FT_HEAD, P.FT_DATA, P.FT_DATA, P.FT_TAIL]
    assert fl[0][1] == h.pack()
    assert fl[3][1] == P.payload_word(h.addr, h.tag, 2) & 0xFF   # 1 byte left in the tail
    hr = P.Header(ptype=P.PT_RD_REQ, len=64)
    assert [t for t, _ in P.packetize(hr)] == [P.FT_HEAD_TAIL]


def test_header_field_positions():
    assert P.Header(src=0xF).pack() == 0xF << 220
    assert P.Header(len=0xFFFF).pack() == 0xFFFF << 184
    assert P.Header(tag=0xFFFF).pack() == 0xFFFF << 168
    assert P.Header(addr=1).pack() == 1 << 120
    assert P.Header(inject_ts=1).pack() == 1 << 56


def test_flit_field_positions():
    f = P.flit_pack(P.FT_TAIL, 0xA5, 1, 0)
    assert f >> 253 == P.FT_TAIL
    assert (f >> 245) & 0xFF == 0xA5
    assert (f >> 244) & 1 == 1
    assert (f >> 240) & 0xF == 0
