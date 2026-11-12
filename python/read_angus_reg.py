"""
Read Angus AXI-Lite registers by name or raw byte address.

Examples:
    sudo -E python read_angus_reg.py AVG_N
    sudo -E python read_angus_reg.py AVG_N AVG_FRAME_COUNT AVG_BAD_TLAST_COUNT
    sudo -E python read_angus_reg.py 0x10C
"""

import argparse
from typing import Iterable

from pynq import Overlay

from angus_regs import ALL_REGS, AngusRegs


def parse_reg_token(token: str) -> tuple[str, int | None]:
    name = token.upper()
    if name in ALL_REGS:
        return name, None

    try:
        return token, int(token, 0)
    except ValueError as exc:
        valid = ", ".join(sorted(ALL_REGS))
        raise SystemExit(f"Unknown register {token!r}. Valid names: {valid}") from exc


def read_regs(regs: AngusRegs, tokens: Iterable[str]) -> int:
    for token in tokens:
        label, raw_addr = parse_reg_token(token)
        if raw_addr is None:
            value = int(regs.read(label))
            addr = ALL_REGS[label][0]
        else:
            value = int(regs.read_raw(raw_addr))
            addr = raw_addr
        print(f"{label:24s} addr=0x{addr:03X} value={value} 0x{value:08X}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Read Angus AXI-Lite registers")
    parser.add_argument("registers", nargs="+", help="Register names or raw byte addresses, e.g. AVG_N 0x10C")
    parser.add_argument("--bitfile", default="/home/xilinx/angus.bit")
    parser.add_argument("--ip-name", default="top_0")
    parser.add_argument("--no-load", action="store_true", help="Do not download the bitstream")
    args = parser.parse_args()

    overlay = Overlay(args.bitfile, download=not args.no_load)
    regs = AngusRegs(getattr(overlay, args.ip_name))
    return read_regs(regs, args.registers)


if __name__ == "__main__":
    raise SystemExit(main())
