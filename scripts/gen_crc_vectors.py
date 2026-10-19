#!/usr/bin/env python3
"""Write random CRC test vectors for tb_crc from the Python golden model.

Each line: <240-bit covered data, 60 hex digits> <16-bit CRC, 4 hex digits>.
Usage: gen_crc_vectors.py N SEED OUT
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))
from tflex.protocol.crc import COVERED_BITS, flit_crc  # noqa: E402


def main():
    n, seed, out = int(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3])
    rng = random.Random(seed)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w") as f:
        for _ in range(n):
            d = rng.getrandbits(COVERED_BITS)
            f.write(f"{d:060x} {flit_crc(d):04x}\n")


if __name__ == "__main__":
    main()
