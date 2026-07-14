#!/usr/bin/env python3
"""
patch-mte-note.py — Remove the MTE ELF note from an aarch64 binary

PROBLEM:
  Android's Bionic linker checks for the GNU_PROPERTY_AARCH64_FEATURE_1_MTE
  ELF note in the binary. If present (and the kernel supports MTE), Bionic
  enables MTE (Memory Tagging Extension) at process startup, BEFORE any
  LD_PRELOAD constructor runs.

  This means:
  - MEMTAG_OPTIONS=off may not work (Bionic bug or kernel override)
  - LD_PRELOAD shims run too late (scudo already initialized)
  - android_mallopt() returns OK but doesn't actually disable tagging

SOLUTION:
  Patch the binary to clear the MTE bit in the ELF note. After patching,
  Bionic won't enable MTE, so:
  - malloc returns untagged pointers
  - free accepts untagged pointers
  - No MTE hardware tag checks

USAGE:
  python3 patch-mte-note.py /path/to/bun
  python3 patch-mte-note.py /path/to/bun --backup   # creates bun.bak
  python3 patch-mte-note.py /path/to/bun --check     # check only, no patch

HOW IT WORKS:
  1. Parse the ELF header to find program headers
  2. Find PT_GNU_PROPERTY (type 0x6474e551)
  3. Parse the note section within it
  4. Find GNU_PROPERTY_AARCH64_FEATURE_1_AND (note type 0xc0000000)
  5. Clear the MTE bit (bit 2, mask 0x4) in the feature flags
  6. Write the patched binary

License: MIT
"""

import struct
import sys
import os
import shutil

# ELF constants
PT_GNU_PROPERTY = 0x6474e551
NT_GNU_PROPERTY_TYPE_0 = 5  # GNU_PROPERTY_AARCH64_FEATURE_1_AND for aarch64
GNU_PROPERTY_AARCH64_FEATURE_1_MTE = 0x4  # bit 2

def read_elf_header(data):
    """Parse the ELF64 header and return (e_phoff, e_phentsize, e_phnum)."""
    if len(data) < 64:
        raise ValueError("File too small to be ELF64")

    # Check ELF magic
    if data[:4] != b'\x7fELF':
        raise ValueError("Not an ELF file")

    # Check it's ELF64
    if data[4] != 2:  # EI_CLASS = ELFCLASS64
        raise ValueError("Not ELF64 (only 64-bit supported)")

    # Check it's aarch64
    e_machine = struct.unpack_from('<H', data, 18)[0]
    if e_machine != 183:  # EM_AARCH64
        raise ValueError(f"Not aarch64 (e_machine={e_machine})")

    # ELF64 header fields
    e_phoff = struct.unpack_from('<Q', data, 32)[0]
    e_phentsize = struct.unpack_from('<H', data, 54)[0]
    e_phnum = struct.unpack_from('<H', data, 56)[0]

    return e_phoff, e_phentsize, e_phnum

def find_gnu_property_phdr(data, e_phoff, e_phentsize, e_phnum):
    """Find the PT_GNU_PROPERTY program header.
    Returns (phdr_offset, p_offset, p_filesz) or None."""
    for i in range(e_phnum):
        phdr_off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from('<I', data, phdr_off)[0]
        if p_type == PT_GNU_PROPERTY:
            p_offset = struct.unpack_from('<Q', data, phdr_off + 8)[0]
            p_filesz = struct.unpack_from('<Q', data, phdr_off + 32)[0]
            return phdr_off, p_offset, p_filesz
    return None

def find_and_patch_mte_note(data, note_offset, note_size):
    """Find the MTE feature note within the GNU_PROPERTY note section.
    Returns the offset of the MTE bit to patch, or None if not found.

    The note section format:
      [namesz (4 bytes)][descsz (4 bytes)][type (4 bytes)]
      [name (padded to 8 bytes)]
      [desc (padded to 8 bytes)]
      ...
    """
    offset = note_offset
    end = note_offset + note_size
    patches = []

    while offset + 12 <= end:
        namesz = struct.unpack_from('<I', data, offset)[0]
        descsz = struct.unpack_from('<I', data, offset + 4)[0]
        ntype = struct.unpack_from('<I', data, offset + 8)[0]

        # Name is padded to 8 bytes
        name_padded = (namesz + 7) & ~7
        # Desc is padded to 8 bytes
        desc_padded = (descsz + 7) & ~7

        desc_offset = offset + 12 + name_padded

        # GNU_PROPERTY_AARCH64_FEATURE_1_AND has:
        #   ntype = 0xc0000000 (NT_GNU_PROPERTY_TYPE_0 = 5, but the actual
        #          note type for aarch64 feature is 0xc0000000)
        #   name = "GNU\0"
        #   desc = 4 bytes of feature flags
        if ntype == 0xc0000000 and descsz >= 4:
            features = struct.unpack_from('<I', data, desc_offset)[0]
            if features & GNU_PROPERTY_AARCH64_FEATURE_1_MTE:
                patches.append((desc_offset, features))
                print(f"  Found MTE note at offset 0x{desc_offset:x}")
                print(f"    Current features: 0x{features:08x}")
                print(f"    MTE bit (0x{GNU_PROPERTY_AARCH64_FEATURE_1_MTE:x}) is SET")

        offset = desc_offset + desc_padded

    return patches

def patch_binary(filepath, backup=True, check_only=False):
    """Patch the binary to clear the MTE bit."""

    print(f"Examining: {filepath}")

    with open(filepath, 'rb') as f:
        data = bytearray(f.read())

    print(f"  File size: {len(data)} bytes")

    # Parse ELF header
    try:
        e_phoff, e_phentsize, e_phnum = read_elf_header(data)
    except ValueError as e:
        print(f"  ERROR: {e}")
        return False

    print(f"  ELF64 aarch64 confirmed")
    print(f"  Program headers: {e_phnum} entries at offset 0x{e_phoff:x}")

    # Find PT_GNU_PROPERTY
    result = find_gnu_property_phdr(data, e_phoff, e_phentsize, e_phnum)
    if result is None:
        print("  No PT_GNU_PROPERTY program header found")
        print("  → Binary does NOT have MTE note — no patching needed")
        return True

    phdr_off, p_offset, p_filesz = result
    print(f"  PT_GNU_PROPERTY: offset=0x{p_offset:x}, size=0x{p_filesz:x}")

    # Find MTE note within the property section
    patches = find_and_patch_mte_note(data, p_offset, p_filesz)

    if not patches:
        print("  No MTE note found in GNU_PROPERTY section")
        print("  → Binary does NOT have MTE enabled — no patching needed")
        return True

    if check_only:
        print(f"\n  CHECK: Found {len(patches)} MTE note(s) — patching needed")
        return True

    # Apply patches
    print(f"\n  Patching {len(patches)} MTE note(s)...")
    for desc_offset, old_features in patches:
        new_features = old_features & ~GNU_PROPERTY_AARCH64_FEATURE_1_MTE
        struct.pack_into('<I', data, desc_offset, new_features)
        print(f"    At 0x{desc_offset:x}: 0x{old_features:08x} → 0x{new_features:08x}")

    # Backup
    if backup:
        bak = filepath + '.bak'
        if not os.path.exists(bak):
            shutil.copy2(filepath, bak)
            print(f"  Backup saved: {bak}")
        else:
            print(f"  Backup already exists: {bak} (not overwriting)")

    # Write patched binary
    with open(filepath, 'wb') as f:
        f.write(data)

    print(f"\n  ✅ Patched: {filepath}")
    print(f"  MTE bit cleared — Bionic will NOT enable MTE for this binary")
    return True

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\nUsage: python3 patch-mte-note.py /path/to/binary [--backup] [--check]")
        sys.exit(1)

    filepath = sys.argv[1]
    backup = '--backup' in sys.argv
    check_only = '--check' in sys.argv

    if not os.path.exists(filepath):
        print(f"ERROR: file not found: {filepath}")
        sys.exit(1)

    if not os.access(filepath, os.W_OK):
        print(f"ERROR: no write permission: {filepath}")
        print("Try: sudo python3 patch-mte-note.py ...")
        sys.exit(1)

    success = patch_binary(filepath, backup=backup, check_only=check_only)
    sys.exit(0 if success else 1)

if __name__ == '__main__':
    main()
