"""Flit, header and packet golden model (docs/protocol.md sections 2-3).

Mirrors rtl/common/tflex_pkg.sv: flit_t, pkt_hdr_t, payload_word() and the
packetizer's HEAD / DATA / TAIL / HEAD_TAIL sequence.
"""
from dataclasses import dataclass

from .crc import flit_crc

BODY_BITS = 224
BODY_BYTES = 28
FLIT_BYTES = 32
SEQ_BITS = 8

# flit_type_e
FT_IDLE, FT_HEAD, FT_DATA, FT_TAIL, FT_HEAD_TAIL = range(5)
# pkt_type_e
PT_WR_REQ, PT_RD_REQ, PT_RD_RESP, PT_WR_ACK = range(4)

_M32 = 0xFFFF_FFFF


def has_payload(ptype: int) -> bool:
    return ptype in (PT_WR_REQ, PT_RD_RESP)


def mix32(x: int) -> int:
    x &= _M32
    x ^= (x << 13) & _M32
    x ^= x >> 17
    x ^= (x << 5) & _M32
    return x


def payload_word(addr: int, tag: int, idx: int) -> int:
    """224-bit payload word idx of transfer (addr, tag), as tflex_pkg::payload_word."""
    seed = ((addr & _M32) ^ (((addr >> 32) & 0xFFFF) << 16)
            ^ (((tag & 0xFFFF) << 16) | (idx & 0xFFFF)) ^ 0x9E37_79B9)
    w = 0
    for j in range(BODY_BITS // 32):
        w |= mix32(mix32(seed ^ ((j << 24) & _M32) ^ 0x1)) << (32 * j)
    return w


def keep_bytes(w: int, nbytes: int) -> int:
    return w & ((1 << (8 * nbytes)) - 1)


@dataclass
class Header:
    """pkt_hdr_t fields; pack() gives the 224-bit body (src in the MSBs)."""
    src: int = 0
    dst: int = 0
    ptype: int = PT_WR_REQ
    tclass: int = 0
    prio: int = 0
    path: int = 0
    len: int = 0
    tag: int = 0
    addr: int = 0
    inject_ts: int = 0

    _FIELDS = (("src", 4), ("dst", 4), ("ptype", 4), ("tclass", 4), ("prio", 2),
               ("path", 2), ("rsvd0", 4), ("len", 16), ("tag", 16), ("addr", 48),
               ("inject_ts", 64), ("rsvd1", 56))

    def pack(self) -> int:
        v = 0
        for name, width in self._FIELDS:
            f = getattr(self, name, 0) if not name.startswith("rsvd") else 0
            assert 0 <= f < (1 << width), f"{name}={f} does not fit {width} bits"
            v = (v << width) | f
        assert v < (1 << BODY_BITS)
        return v

    def payload_len(self) -> int:
        return self.len if has_payload(self.ptype) else 0


def data_flits(payload_len: int) -> int:
    return -(-payload_len // BODY_BYTES)


def packet_flits(payload_len: int) -> int:
    """Flits of a packet: one header flit plus ceil(len/28) data flits."""
    return 1 + data_flits(payload_len)


def payload_efficiency(payload_len: int) -> float:
    return payload_len / (packet_flits(payload_len) * FLIT_BYTES)


def packetize(h: Header):
    """List of (ftype, body) flit bodies for one packet, as tflex_packetizer emits them."""
    n = data_flits(h.payload_len())
    if n == 0:
        return [(FT_HEAD_TAIL, h.pack())]
    out = [(FT_HEAD, h.pack())]
    for i in range(n):
        left = h.payload_len() - i * BODY_BYTES
        w = payload_word(h.addr, h.tag, i)
        out.append((FT_TAIL if i == n - 1 else FT_DATA,
                    keep_bytes(w, min(left, BODY_BYTES))))
    return out


def flit_covered(ftype: int, seq: int, replay: int, body: int) -> int:
    """Bits 255:16 of a flit: ftype[2:0] seq[7:0] replay rsvd[3:0]=0 body[223:0]."""
    assert 0 <= ftype < 8 and 0 <= seq < 256 and replay in (0, 1) and 0 <= body < (1 << BODY_BITS)
    return (ftype << 237) | (seq << 229) | (replay << 228) | body


def flit_pack(ftype: int, seq: int, replay: int, body: int) -> int:
    cov = flit_covered(ftype, seq, replay, body)
    return (cov << 16) | flit_crc(cov)
