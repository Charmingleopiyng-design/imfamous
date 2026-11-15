#!/usr/bin/env python3
"""Adds a WEAK LC_LOAD_DYLIB for @rpath/RecRedirect.framework/RecRedirect to an arm64 iOS
Mach-O executable, so the framework loads before main() but the app still starts if it can't.

The new entry is APPENDED after the existing library entries. Library ordinals (used by the
binary's symbol bindings) are positions in that list, so inserting anywhere else would
re-point every import at the wrong library and crash the app.
The old code signature is removed (Sideloadly / codesign signs it again).

usage: patch_executable.py <input RecRoom> <output RecRoom>
"""
import struct, sys

LOAD_DYLIB_PATH = "@rpath/RecRedirect.framework/RecRedirect"
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB = 0xC, 0x80000018, 0x8000001F, 0x80000023
DYLIB_CMDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB)
LC_CODE_SIGNATURE, LC_ENCRYPTION_INFO_64, LC_DYLD_CHAINED_FIXUPS = 0x1D, 0x2C, 0x80000034


def parse(d):
    magic, cpu, sub, ft, ncmds, sizeofcmds, flags, res = struct.unpack("<8I", d[:32])
    if magic != 0xFEEDFACF:
        sys.exit("not a thin 64-bit Mach-O (thin the arm64 slice first)")
    cmds, off = [], 32
    for _ in range(ncmds):
        c, s = struct.unpack("<II", d[off:off + 8])
        cmds.append((c, bytes(d[off:off + s])))
        off += s
    return cmds, sizeofcmds


def dylib_name(b):
    return b[struct.unpack("<I", b[8:12])[0]:].split(b"\0")[0].decode()


def ordinals(d):
    """(libs in ordinal order, [(symbol, ordinal)]) from chained fixups"""
    cmds, _ = parse(d)
    libs = [dylib_name(b) for c, b in cmds if c in DYLIB_CMDS]
    imports = []
    for c, b in cmds:
        if c == LC_DYLD_CHAINED_FIXUPS:
            dataoff = struct.unpack("<I", b[8:12])[0]
            h = d[dataoff:dataoff + 28]
            _, _, imp_off, sym_off, cnt, fmt, _ = struct.unpack("<7I", h)
            base = dataoff + imp_off
            for i in range(cnt):
                if fmt == 1:
                    v = struct.unpack("<I", d[base + i * 4:base + i * 4 + 4])[0]
                    lib, name = v & 0xFF, v >> 9
                elif fmt == 2:
                    v = struct.unpack("<I", d[base + i * 8:base + i * 8 + 4])[0]
                    lib, name = v & 0xFF, v >> 9
                else:
                    v = struct.unpack("<Q", d[base + i * 8:base + i * 8 + 8])[0]
                    lib, name = v & 0xFFFF, (v >> 32)
                s0 = dataoff + sym_off + name
                imports.append((d[s0:d.index(b"\0", s0)].decode(), lib))
    return libs, imports


def main(src, dst):
    d = bytearray(open(src, "rb").read())
    cmds, sizeofcmds = parse(d)

    for c, b in cmds:
        if c == LC_ENCRYPTION_INFO_64 and struct.unpack("<I", b[16:20])[0] != 0:
            sys.exit("binary is FairPlay-encrypted (cryptid != 0): use a decrypted IPA")
        if c in DYLIB_CMDS and LOAD_DYLIB_PATH == dylib_name(b):
            sys.exit("already patched")

    nm = LOAD_DYLIB_PATH.encode() + b"\0"
    size = (24 + len(nm) + 7) & ~7
    new = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, size, 24, 2, 0x00010000, 0x00010000)
    new += nm + b"\0" * (size - 24 - len(nm))

    last_dylib = max(i for i, (c, _) in enumerate(cmds) if c in DYLIB_CMDS)

    sig_off = None
    out = []
    for i, (c, b) in enumerate(cmds):
        if c == LC_CODE_SIGNATURE:
            sig_off = struct.unpack("<I", b[8:12])[0]
            continue
        out.append((c, b))
        if i == last_dylib:
            out.append((LC_LOAD_WEAK_DYLIB, new))      # <- appended after the last library

    if sig_off is not None:
        fixed = []
        for c, b in out:
            if c == LC_SEGMENT_64 and b[8:24].rstrip(b"\0") == b"__LINKEDIT":
                b = bytearray(b)
                vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", b[24:56])
                filesize = sig_off - fileoff
                vmsize = (filesize + 0x3FFF) & ~0x3FFF
                b[24:56] = struct.pack("<QQQQ", vmaddr, vmsize, fileoff, filesize)
                b = bytes(b)
            fixed.append((c, b))
        out = fixed
        del d[sig_off:]

    blob = b"".join(b for _, b in out)
    first_sect = min(
        o for c, b in out if c == LC_SEGMENT_64
        for i in range(struct.unpack("<I", b[64:68])[0])
        for o in [struct.unpack("<I", b[72 + i * 80 + 48:72 + i * 80 + 52])[0]] if o
    )
    if 32 + len(blob) > first_sect:
        sys.exit("not enough header space for the new load command")

    end_old = 32 + sizeofcmds
    d[32:32 + len(blob)] = blob
    if end_old > 32 + len(blob):
        d[32 + len(blob):end_old] = b"\0" * (end_old - 32 - len(blob))
    d[16:24] = struct.pack("<II", len(out), len(blob))

    # ---- self-check: every symbol must still bind to the same library as before ----
    old_libs, old_imp = ordinals(open(src, "rb").read())
    new_libs, new_imp = ordinals(bytes(d))
    assert new_libs[:len(old_libs)] == old_libs, "library order changed!"
    assert new_libs[-1] == LOAD_DYLIB_PATH, "new library not last!"
    assert old_imp == new_imp, "import bindings changed!"
    for sym, lib in new_imp:
        if 1 <= lib <= len(new_libs):
            assert new_libs[lib - 1] == old_libs[lib - 1], f"{sym} now bound to wrong library"

    open(dst, "wb").write(d)
    print(f"patched OK: weak-loads {LOAD_DYLIB_PATH} as library #{len(new_libs)} "
          f"(existing 1..{len(old_libs)} untouched, {len(new_imp)} imports verified), signature removed")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
