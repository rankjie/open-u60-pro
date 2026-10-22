#!/usr/bin/env python3
"""Restore the existing WMS arrival event on the inspected MU5250 firmware."""
import argparse
from pathlib import Path
import struct

PATCH_SITE = 0x2AA14
TRAMPOLINE = 0x46F20
PIPE_SENDER = 0x2F22C
RESUME = 0x2A904
TEXT_END = 0x46F1C
PATCHED_END = 0x46F30
ANCHORS = {
    0x2A5DC: bytes.fromhex("0c9882d2ff632ccb050282d2a4000090"),
    PIPE_SENDER: bytes.fromhex("0c0c85d2ff632ccb8301009063f042f9"),
    0x2EBCC: bytes.fromhex("fd7bb9a9c3008052420c8452fd030091"),
    PATCH_SITE: bytes.fromhex("bcffff17"),
    0x3F811: b"zwrt_wms_status_event\0",
}


def branch(address: int, destination: int, *, link: bool = False) -> bytes:
    displacement = destination - address
    if displacement % 4 or not -(1 << 27) <= displacement < (1 << 27):
        raise ValueError("Unencodable AArch64 branch")
    return struct.pack("<I", (0x94000000 if link else 0x14000000)
                       | ((displacement // 4) & 0x3FFFFFF))


def patch(data: bytes) -> bytes:
    if (len(data) != 328325 or data[:6] != b"\x7fELF\x02\x01"
            or struct.unpack_from("<H", data, 18)[0] != 183):
        raise ValueError("Unsupported WMS executable")
    if any(data[offset:offset + len(value)] != value for offset, value in ANCHORS.items()):
        raise ValueError("WMS receive/notification code differs from the inspected firmware")
    if any(data[TEXT_END:PATCHED_END]):
        raise ValueError("WMS executable padding is occupied")
    phoff = struct.unpack_from("<Q", data, 32)[0]
    entsize, count = struct.unpack_from("<HH", data, 54)
    if entsize != 56 or phoff + count * entsize > len(data):
        raise ValueError("Invalid WMS program headers")
    segments = []
    for index in range(count):
        base = phoff + index * entsize
        kind, flags, offset, address, _, size, memory, _ = struct.unpack_from("<IIQQQQQQ", data, base)
        if kind == 1 and offset == address == 0:
            if flags != 5 or size != TEXT_END or memory != TEXT_END:
                raise ValueError("Unexpected WMS executable segment")
            segments.append(base)
        elif kind == 1 and offset < PATCHED_END:
            raise ValueError("Overlapping WMS segment")
    if len(segments) != 1:
        raise ValueError("WMS executable segment is ambiguous")

    result = bytearray(data)
    result[PATCH_SITE:PATCH_SITE + 4] = branch(PATCH_SITE, TRAMPOLINE)
    # Reuse the native pipe: the ubus context belongs to the uloop thread,
    # while stored-message handling runs on the modem command queue.
    result[TRAMPOLINE:PATCHED_END] = (
        struct.pack("<II", 0x52800000, 0xD2800001)  # w0=received command, x1=NULL
        + branch(TRAMPOLINE + 8, PIPE_SENDER, link=True)
        + branch(TRAMPOLINE + 12, RESUME))
    struct.pack_into("<QQ", result, segments[0] + 32, PATCHED_END, PATCHED_END)
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = patch(args.input.read_bytes())
    with args.output.open("xb") as output:
        output.write(result)
    args.output.chmod(0o755)
    print("Prepared WMS arrival-event fix; the input executable was preserved.")


if __name__ == "__main__":
    main()
