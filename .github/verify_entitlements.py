#!/usr/bin/env python3
"""Verify the Sealbox app binary carries the App Group entitlement.

Parses the code-signature superblob of the main executable (Mach-O,
LC_CODE_SIGNATURE) and checks the entitlements slot (CSSLOT_ENTITLEMENTS=5)
for com.apple.security.application-groups containing group.com.mjorb.sealbox.

This is the build-time gate for the 0.1.0 bug where CI shipped a fully
unsigned IPA: without any signature Seal reads no entitlements at all, so
assignAppGroups has no group to allocate and the re-signed app has no
App Group permission (containerURL returns nil, certificate import fails
with "取不到应用共享目录").

Usage: verify_entitlements.py <SealBox.app path>
Exits 0 on pass, 1 on any failure (missing signature, missing slot, or
missing/wrong group). Pure struct + plistlib, no codesign/otool dependency;
same Mach-O parsing approach as the F4 binary check.
"""
import plistlib
import struct
import sys
from pathlib import Path

EXPECTED_GROUP = "group.com.mjorb.sealbox"

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_BLOBWRAPPER = 0xFADE7171
CSSLOT_ENTITLEMENTS = 5
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_ARM64 = 0x0100000C


def fail(msg):
    print(f"ENTITLEMENTS CHECK FAILED: {msg}", file=sys.stderr)
    sys.exit(1)


def thin_slice(data):
    """Return the arm64 Mach-O bytes: thin 64-bit as-is, FAT sliced to arm64."""
    if len(data) < 4:
        fail("binary too small to be a Mach-O")
    magic_be = struct.unpack(">I", data[:4])[0]
    if magic_be == FAT_MAGIC:
        (nfat,) = struct.unpack(">I", data[4:8])
        for i in range(nfat):
            off = 8 + i * 20
            cputype, _, offset, size, _ = struct.unpack(">IIIII", data[off:off + 20])
            if cputype == CPU_TYPE_ARM64:
                return data[offset:offset + size]
        fail("FAT binary has no arm64 slice")
    magic_le = struct.unpack("<I", data[:4])[0]
    if magic_le != MH_MAGIC_64:
        fail(f"not a 64-bit Mach-O (magic {magic_le:#x})")
    return data


def code_signature_range(macho):
    """Return (dataoff, datasize) of LC_CODE_SIGNATURE."""
    (ncmds,) = struct.unpack_from("<I", macho, 16)
    off = 32  # sizeof(struct mach_header_64)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", macho, off)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", macho, off + 8)
            return dataoff, datasize
        off += cmdsize
    fail("no LC_CODE_SIGNATURE load command (binary is unsigned)")


def entitlements_plist(macho):
    dataoff, datasize = code_signature_range(macho)
    blob = macho[dataoff:dataoff + datasize]
    if len(blob) < 12:
        fail("code signature superblob too small")
    magic, _length, count = struct.unpack_from(">III", blob, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        fail(f"bad superblob magic {magic:#x}")
    ent_off = None
    for i in range(count):
        slot_type, slot_off = struct.unpack_from(">II", blob, 12 + i * 8)
        if slot_type == CSSLOT_ENTITLEMENTS:
            ent_off = slot_off
            break
    if ent_off is None:
        fail("no entitlements slot (type 5) in code signature")
    if ent_off + 8 > len(blob):
        fail("entitlements slot offset out of range")
    bmagic, blength = struct.unpack_from(">II", blob, ent_off)
    if bmagic != CSMAGIC_BLOBWRAPPER:
        fail(f"bad entitlements blob magic {bmagic:#x}")
    if ent_off + blength > len(blob) or blength < 8:
        fail("entitlements blob length out of range")
    return blob[ent_off + 8:ent_off + blength]


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <SealBox.app path>", file=sys.stderr)
        sys.exit(2)
    app = Path(sys.argv[1])
    binary = app / "SealBox"
    if not app.is_dir():
        fail(f"app bundle not found: {app}")
    if not (app / "_CodeSignature" / "CodeResources").is_file():
        fail(f"app is not signed: {app}/_CodeSignature/CodeResources missing")
    if not binary.is_file():
        fail(f"main executable not found: {binary}")
    ent_data = entitlements_plist(thin_slice(binary.read_bytes()))
    try:
        ent = plistlib.loads(ent_data)
    except Exception as exc:
        fail(f"entitlements slot is not a valid plist: {exc}")
    groups = ent.get("com.apple.security.application-groups")
    if not isinstance(groups, list) or EXPECTED_GROUP not in groups:
        fail(
            "com.apple.security.application-groups missing or wrong: "
            f"got {groups!r}, expected to contain {EXPECTED_GROUP!r}"
        )
    print(f"ENTITLEMENTS CHECK PASSED: application-groups = {groups!r}")


if __name__ == "__main__":
    main()
