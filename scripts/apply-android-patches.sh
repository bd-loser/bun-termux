#!/usr/bin/env bash
# apply-android-patches.sh — patches Bun v1.3.14 (Zig) for Android/Termux
#
# ROBUSTNESS RULES (learned from previous failed attempts):
#   1. Use line-number-based patching with semantic anchors, not exact
#      string matching. Triple-quoted Python strings silently fail on
#      any whitespace difference.
#   2. Verify EVERY patch applied. Abort the build if any patch failed.
#   3. Print clear [OK]/[FAIL] markers so CI logs are greppable.
#   4. Idempotent: safe to re-run. Detects existing patches via markers.
#
# === HYBRID APPROACH: source patches + LD_PRELOAD shim ===
#
# Bun's directory resolver uses std.fs.openDirAbsoluteZ which calls
# Zig's std.os.linux.openat — a RAW SYSCALL (inline asm, NOT libc).
# LD_PRELOAD shims can only intercept libc function calls, NOT raw
# syscalls. Therefore:
#
# - Source patches (Layers 1a/1b/2) are REQUIRED for the resolver walk
#   (they prevent the raw syscall from ever hitting /, or handle the
#   error in Zig's error handling)
# - The LD_PRELOAD shim (libbun-android-fix.so) handles everything that
#   goes through libc: linkat/symlinkat (bun install), fopen (DNS),
#   mkdir/symlink (/tmp), execve (shebangs), /proc/stat (os.cpus())
#
# Both are needed. Neither alone is sufficient.
#
# WHAT THIS PATCHES (Bun v1.3.14 Zig codebase):
#
#   1. src/resolver/resolver.zig — THE bunx fix (2 changes, ancestor walk PRESERVED):
#      a) Walk error switch: on AccessDenied, CONTINUE to the next
#         queue item instead of returning null. Skips inaccessible
#         ancestors (/, /data) while still processing accessible ones.
#         This is the PRIMARY fix — ancestor walking is preserved,
#         so enclosing package.json from parent dirs IS found (monorepo
#         support works!).
#      b) DirEntry cache .err branch: on AccessDenied, don't return the
#         cached error. Without this, a previously-cached EACCES on "/"
#         would propagate as an error on subsequent walks, bypassing (a).
#         This lets root_path be queued, and (a) handles it in processing.
#
#      NOTE: Previous versions had a Layer 1a (root_path = path) that
#      prevented ancestor walking entirely. This is NO LONGER NEEDED
#      because 1a+1b together handle all AccessDenied cases. Removing
#      1a RESTORES MONOREPO SUPPORT (ancestor walking works).
#
#   2. src/cli/run_command.zig — CouldntReadCurrentDirectory fallback:
#      When readDirInfo returns null (walk failed), create a minimal
#      DirInfo from the cwd instead of erroring out.
#
#   3. src/exe_format/elf.zig — bun build --compile fix (2 changes):
#      a) writeBunSection: pick the LAST writable PT_LOAD instead of the
#         first. With RELRO, the linker can emit two RW PT_LOADs (one
#         RELRO-covered, one not). Growing the first would swallow the
#         second, producing overlapping PT_LOADs that Bionic's linker64
#         rejects with "CANNOT LINK EXECUTABLE". Picking the last RW
#         PT_LOAD (highest vaddr) means the extension goes past all
#         other PT_LOADs — no overlap. Works for both single-RW and
#         split-RW layouts, doesn't regress WSL1.
#      b) Defensive overlap check after extension — returns a clear
#         error if the extended segment would overlap another PT_LOAD,
#         instead of silently producing a broken binary.
#
#   4. scripts/build/config.ts — enable TinyCC for Android (bun:ffi callback support)
#   5. scripts/build/deps/tinycc.ts — add Android/Bionic defines to TinyCC build
#   6. scripts/build/flags.ts — cross-compile CPU flag fix
#   7. scripts/build/tools.ts — accept NDK clang 18
#   8. C++ dangling-reference fix for clang 18
#
set -euo pipefail

BUN_SRC="${1:-.}"
PATCH_MARKER="ANDROID_TERMUX_FIX"
FAIL_COUNT=0

cd "$BUN_SRC"

echo "=========================================="
echo "Applying Android/Termux patches to Bun v1.3.14"
echo "Source: $BUN_SRC"
echo "Approach: source patches (resolver walk) + LD_PRELOAD shim (libc calls)"
echo "=========================================="

# === Helper: verify a patch was applied ===
verify_patch() {
    local file="$1"
    local marker="$2"
    if grep -q "$marker" "$file" 2>/dev/null; then
        echo "  [OK] $file: $marker found"
        return 0
    else
        echo "  [FAIL] $file: $marker NOT found — patch did not apply!"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

# =====================================================================
# PATCH 1: src/resolver/resolver.zig — THE bunx fix
# =====================================================================
RESOLVER_ZIG="src/resolver/resolver.zig"

if [ ! -f "$RESOLVER_ZIG" ]; then
    echo "  [FAIL] $RESOLVER_ZIG not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if grep -q "$PATCH_MARKER" "$RESOLVER_ZIG" 2>/dev/null; then
        echo "  [SKIP] $RESOLVER_ZIG already patched"
    else
        echo "  [PATCH] $RESOLVER_ZIG"
        python3 <<'PYEOF'
import re, sys

with open("src/resolver/resolver.zig", "r") as f:
    content = f.read()

patched = 0

# 1a: Walk error switch — add AccessDenied => continue (PRIMARY FIX)
# This is in the queue PROCESSING loop. When openDirAbsoluteZ returns
# EACCES for / or /data, skip this ancestor and continue to the next.
# The cwd at queue[0] is always accessible.
old_switch = r'''                    error\.ENOTDIR, error\.IsDir, error\.NotDir => return null,'''

new_switch = '''                    // ANDROID_TERMUX_FIX [Layer 1a]: On AccessDenied (EACCES), skip this
                    // ancestor and CONTINUE processing the rest of the queue. The cwd
                    // at queue[0] is always accessible — returning null would abort
                    // the entire walk and never try the cwd. Ancestor walking is
                    // PRESERVED (monorepo support works).
                    error.ENOTDIR, error.IsDir, error.NotDir => return null,
                    error.AccessDenied => {
                        r.dir_cache.markNotFound(queue_top.result);
                        const cached_dir_entry_result = rfs.entries.getOrPut(queue_top.unsafe_path) catch unreachable;
                        rfs.entries.markNotFound(cached_dir_entry_result);
                        continue;
                    },'''

new_content = re.sub(old_switch, lambda m: new_switch, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [1a] AccessDenied => continue in processing loop (PRIMARY FIX)")
else:
    print("    [FAIL] could not find walk error switch pattern")
    sys.exit(1)

# 1b: DirEntry cache .err branch — don't return AccessDenied (CACHE FIX)
# This is in the queue QUEUING phase (if top == root_path block). Without
# this, a previously-cached EACCES on "/" would propagate as an error on
# subsequent walks, bypassing Layer 1a entirely. With this, root_path
# gets queued, and Layer 1a handles EACCES in the processing loop.
old_err = r'''                        \.err => \|err\| \{
                            debuglog\("Failed to load DirEntry \{s\}  \{s\} - \{s\}", \.\{ top, @errorName\(err\.original_err\), @errorName\(err\.canonical_error\) \}\);
                            return err\.canonical_error;
                        \},'''

new_err = '''                        .err => |err| {
                            // ANDROID_TERMUX_FIX [Layer 1b]: On AccessDenied, don't return
                            // the cached error. Let root_path be queued — Layer 1a will
                            // handle EACCES in the processing loop. Without this, a
                            // previously-cached EACCES on "/" would propagate as an error
                            // on subsequent walks, bypassing Layer 1a.
                            if (err.canonical_error != error.AccessDenied) {
                                debuglog("Failed to load DirEntry {s}  {s} - {s}", .{ top, @errorName(err.original_err), @errorName(err.canonical_error) });
                                return err.canonical_error;
                            }
                            // AccessDenied: fall through (root_path gets queued, Layer 1a handles it)
                        },'''

new_content = re.sub(old_err, lambda m: new_err, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [1b] DirEntry cache .err: don't return AccessDenied (CACHE FIX)")
else:
    print("    [FAIL] could not find .err branch pattern")
    sys.exit(1)

with open("src/resolver/resolver.zig", "w") as f:
    f.write(content)

print(f"    Total: {patched}/2 sub-patches applied to resolver.zig")
print(f"    Ancestor walking PRESERVED (monorepo support works!)")
PYEOF
        verify_patch "$RESOLVER_ZIG" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 2: src/cli/run_command.zig — CouldntReadCurrentDirectory fallback
# =====================================================================
RUN_CMD="src/cli/run_command.zig"

if [ ! -f "$RUN_CMD" ]; then
    echo "  [FAIL] $RUN_CMD not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if grep -q "$PATCH_MARKER" "$RUN_CMD" 2>/dev/null; then
        echo "  [SKIP] $RUN_CMD already patched"
    else
        echo "  [PATCH] $RUN_CMD"
        python3 <<'PYEOF'
import re, sys

with open("src/cli/run_command.zig", "r") as f:
    content = f.read()

patched = 0

old = r'''        const root_dir_info = this_transpiler\.resolver\.readDirInfo\(this_transpiler\.fs\.top_level_dir\) catch \|err\| \{
            if \(!log_errors\) return error\.CouldntReadCurrentDirectory;
            ctx\.log\.print\(Output\.errorWriter\(\)\) catch \{\};
            Output\.prettyErrorln\("<r><red>error<r><d>:<r> <b>\{s\}<r> loading directory \{f\}", \.\{ @errorName\(err\), bun\.fmt\.QuotedFormatter\{ \.text = this_transpiler\.fs\.top_level_dir \} \}\);
            Output\.flush\(\);
            return err;
        \} orelse \{
            ctx\.log\.print\(Output\.errorWriter\(\)\) catch \{\};
            Output\.prettyErrorln\("error loading current directory", \.\{\}\);
            Output\.flush\(\);
            return error\.CouldntReadCurrentDirectory;
        \};'''

new = '''        // ANDROID_TERMUX_FIX [Layer 2]: On Android, readDirInfo may return null when
        // the directory walk is blocked by SELinux (EACCES on / or /data via raw
        // syscall that the LD_PRELOAD shim cannot intercept). Instead of failing,
        // create a minimal DirInfo from the cwd so bunx/bun-run can proceed.
        const root_dir_info: *DirInfo = blk: {
            const result = this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir) catch null;
            if (result) |info| break :blk info;
            // readDirInfo returned null — synthesize a minimal DirInfo.
            // Use a unique cache key (with counter) to avoid poisoned cache.
            const cwd = this_transpiler.fs.top_level_dir;
            var key_buf: [bun.MAX_PATH_BYTES + 16]u8 = undefined;
            const key = std.fmt.bufPrintZ(&key_buf, "{s}__termux_{d}", .{ cwd, std.time.milliTimestamp() }) catch break :blk {
                if (!log_errors) return error.CouldntReadCurrentDirectory;
                Output.prettyErrorln("error loading current directory (termux fallback OOM)", .{});
                Output.flush();
                return error.CouldntReadCurrentDirectory;
            };
            var cache_result = this_transpiler.resolver.dir_cache.getOrPut(key) catch break :blk {
                if (!log_errors) return error.CouldntReadCurrentDirectory;
                Output.prettyErrorln("error loading current directory (termux fallback cache)", .{});
                Output.flush();
                return error.CouldntReadCurrentDirectory;
            };
            break :blk this_transpiler.resolver.dir_cache.put(&cache_result, DirInfo{
                .abs_path = cwd,
            }) catch {
                if (!log_errors) return error.CouldntReadCurrentDirectory;
                Output.prettyErrorln("error loading current directory (termux fallback put)", .{});
                Output.flush();
                return error.CouldntReadCurrentDirectory;
            };
        };'''

new_content = re.sub(old, lambda m: new, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [2a] readDirInfo orelse → cwd fallback DirInfo")
else:
    print("    [FAIL] could not find readDirInfo pattern in run_command.zig")
    sys.exit(1)

with open("src/cli/run_command.zig", "w") as f:
    f.write(content)

print(f"    Total: {patched}/1 sub-patches applied to run_command.zig")
PYEOF
        verify_patch "$RUN_CMD" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 3: src/exe_format/elf.zig — bun build --compile fix
# =====================================================================
ELF_ZIG="src/exe_format/elf.zig"

if [ ! -f "$ELF_ZIG" ]; then
    echo "  [FAIL] $ELF_ZIG not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if grep -q "$PATCH_MARKER" "$ELF_ZIG" 2>/dev/null; then
        echo "  [SKIP] $ELF_ZIG already patched"
    else
        echo "  [PATCH] $ELF_ZIG"
        python3 <<'PYEOF'
import re, sys

with open("src/exe_format/elf.zig", "r") as f:
    content = f.read()

patched = 0

# 4a: Pick the LAST writable PT_LOAD instead of the first
old_pick = r'''            if \(\(phdr\.p_flags & elf\.PF_W\) != 0 and rw_phdr_index == null\) \{
                rw_phdr_index = i;
                rw_phdr = phdr;
            \}'''

new_pick = '''            // ANDROID_TERMUX_FIX [Layer 4a]: Pick the LAST writable PT_LOAD
            if ((phdr.p_flags & elf.PF_W) != 0) {
                rw_phdr_index = i;
                rw_phdr = phdr;
            }'''

new_content = re.sub(old_pick, lambda m: new_pick, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [4a] Pick LAST writable PT_LOAD (fixes RELRO overlap)")
else:
    print("    [FAIL] could not find PT_LOAD selection pattern")
    sys.exit(1)

# 4b: Add sh_addr to BunSectionInfo (needed for offset computation)
old_struct = r'''    const BunSectionInfo = struct \{
        /// File offset of the \.bun section's data \(sh_offset\)\.
        file_offset: u64,
        /// Index of the \.bun section in the section header table\.
        section_index: u16,
    \};'''

new_struct = '''    const BunSectionInfo = struct {
        /// File offset of the .bun section's data (sh_offset).
        file_offset: u64,
        /// Index of the .bun section in the section header table.
        section_index: u16,
        /// ANDROID_TERMUX_FIX: Virtual address of .bun section (sh_addr).
        sh_addr: u64,
    };'''

new_content = re.sub(old_struct, lambda m: new_struct, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [4b] Add sh_addr to BunSectionInfo")
else:
    print("    [FAIL] could not find BunSectionInfo struct")
    sys.exit(1)

# 4c: Return sh_addr from findBunSection
old_return = r'''                    return \.\{
                        \.file_offset = shdr\.sh_offset,
                        \.section_index = @intCast\(i\),
                    \};'''

new_return = '''                    return .{
                        .file_offset = shdr.sh_offset,
                        .section_index = @intCast(i),
                        .sh_addr = shdr.sh_addr, // ANDROID_TERMUX_FIX
                    };'''

new_content = re.sub(old_return, lambda m: new_return, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [4c] Return sh_addr from findBunSection")
else:
    print("    [FAIL] could not find findBunSection return")
    sys.exit(1)

# 4d: Write OFFSET instead of absolute vaddr to BUN_COMPILED.size
# This is the KEY fix for PIE/ASLR: on Android, PIE binaries are loaded
# at a random base address. The runtime can't use @ptrFromInt(vaddr)
# because vaddr is relative to 0, not to the load base. By storing the
# offset from BUN_COMPILED to the payload, the runtime can use pointer
# arithmetic (which automatically accounts for the base).
old_write = r'''std\.mem\.writeInt\(u64, self\.data\.items\[bun_section_offset\.\.\]\[0\.\.8\], new_vaddr, \.little\);'''

new_write = '''// ANDROID_TERMUX_FIX [Layer 4d]: Write OFFSET (not absolute vaddr)
                    // to BUN_COMPILED.size. On PIE binaries (required on Android),
                    // the binary is loaded at a random ASLR base. The runtime can't
                    // use @ptrFromInt(vaddr) — it must use pointer arithmetic:
                    //   target = &BUN_COMPILED + offset
                    // This automatically accounts for the ASLR base.
                    const bun_offset = new_vaddr - bun_section.sh_addr;
                    std.mem.writeInt(u64, self.data.items[bun_section_offset..][0..8], bun_offset, .little);'''

new_content = re.sub(old_write, lambda m: new_write, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [4d] Write OFFSET (not vaddr) to BUN_COMPILED.size (PIE/ASLR fix)")
else:
    print("    [FAIL] could not find BUN_COMPILED.size write")
    sys.exit(1)

# 4e: Defensive overlap check
old_extend_end = r'''            const phdr_offset = @as\(usize, @intCast\(ehdr\.e_phoff\)\) \+ rw_index \* phdr_size;
            @memcpy\(self\.data\.items\[phdr_offset\.\.\]\[0\.\.phdr_size\], std\.mem\.asBytes\(&extended\)\);
        \}
    \}'''

new_extend_end = '''            const phdr_offset = @as(usize, @intCast(ehdr.e_phoff)) + rw_index * phdr_size;
            @memcpy(self.data.items[phdr_offset..][0..phdr_size], std.mem.asBytes(&extended));

            // ANDROID_TERMUX_FIX [Layer 4e]: Defensive overlap check.
            const new_end = rw_phdr.p_vaddr + new_segment_size;
            for (0..ehdr.e_phnum) |j| {
                if (j == rw_index) continue;
                const other_offset = @as(usize, @intCast(ehdr.e_phoff)) + j * phdr_size;
                const other_phdr = std.mem.bytesAsValue(Elf64_Phdr, self.data.items[other_offset..][0..phdr_size]).*;
                if (other_phdr.p_type != elf.PT_LOAD) continue;
                const other_end = other_phdr.p_vaddr + other_phdr.p_memsz;
                if (other_phdr.p_vaddr < new_end and other_end > rw_phdr.p_vaddr) {
                    return error.ExtendedSegmentWouldOverlap;
                }
            }
        }
    }'''

new_content = re.sub(old_extend_end, lambda m: new_extend_end, content, count=1)
if new_content != content:
    content = new_content
    patched += 1
    print("    [4e] Defensive overlap check after extension")
else:
    print("    [FAIL] could not find extension block pattern")
    sys.exit(1)

with open("src/exe_format/elf.zig", "w") as f:
    f.write(content)

print(f"    Total: {patched}/5 sub-patches applied to elf.zig")
PYEOF
        verify_patch "$ELF_ZIG" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 3b: src/standalone_graph/StandaloneModuleGraph.zig — PIE/ASLR fix
# =====================================================================
SMG_ZIG="src/standalone_graph/StandaloneModuleGraph.zig"

if [ ! -f "$SMG_ZIG" ]; then
    echo "  [FAIL] $SMG_ZIG not found"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    if grep -q "$PATCH_MARKER" "$SMG_ZIG" 2>/dev/null; then
        echo "  [SKIP] $SMG_ZIG already patched"
    else
        echo "  [PATCH] $SMG_ZIG"
        python3 <<'PYEOF'
import re, sys

with open("src/standalone_graph/StandaloneModuleGraph.zig", "r") as f:
    content = f.read()

# Change getData() to use pointer arithmetic instead of @ptrFromInt(vaddr)
# Bug: @ptrFromInt(vaddr) uses the raw ELF vaddr as an ABSOLUTE address.
# On PIE binaries (required on Android), the binary is loaded at a random
# ASLR base. The payload is at base+vaddr, not at vaddr.
# Fix: use &BUN_COMPILED + offset (pointer arithmetic accounts for base).
old = r'''        pub fn getData\(\) \?\[\]const u8 \{
            const vaddr = \(Bun__getStandaloneModuleGraphELFVaddr\(\) orelse return null\)\.\*;
            if \(vaddr == 0\) return null;
            // BUN_COMPILED\.size holds the virtual address of the appended data\.
            // The kernel mapped it via PT_LOAD, so we can dereference directly\.
            // Format at target: \[u64 payload_len\]\[payload bytes\]
            const target: \[\*\]const u8 = @ptrFromInt\(vaddr\);
            const payload_len = std\.mem\.readInt\(u64, target\[0\.\.8\], \.little\);
            if \(payload_len < 8\) return null;
            return target\[8\.\.\]\[0\.\.payload_len\];
        \}'''

new = '''        pub fn getData() ?[]const u8 {
            // ANDROID_TERMUX_FIX: Use pointer arithmetic instead of @ptrFromInt.
            // On PIE binaries (required on Android), the binary is loaded at a
            // random ASLR base. BUN_COMPILED.size now stores an OFFSET (not an
            // absolute vaddr). We compute: target = &BUN_COMPILED + offset.
            // This automatically accounts for the ASLR base address.
            const ptr = Bun__getStandaloneModuleGraphELFVaddr() orelse return null;
            const offset = ptr.*;
            if (offset == 0) return null;
            const ptr_addr: usize = @intFromPtr(ptr);
            const target: [*]const u8 = @ptrFromInt(ptr_addr + offset);
            const payload_len = std.mem.readInt(u64, target[0..8], .little);
            if (payload_len < 8) return null;
            return target[8..][0..payload_len];
        }'''

new_content = re.sub(old, lambda m: new, content, count=1)
if new_content != content:
    content = new_content
    print("    [5a] Use pointer arithmetic for PIE/ASLR (offset instead of vaddr)")
else:
    print("    [FAIL] could not find getData() pattern")
    sys.exit(1)

with open("src/standalone_graph/StandaloneModuleGraph.zig", "w") as f:
    f.write(content)

print("    Total: 1/1 sub-patches applied to StandaloneModuleGraph.zig")
PYEOF
        verify_patch "$SMG_ZIG" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 4: scripts/build/config.ts — enable TinyCC for Android
# =====================================================================
# Bun disables TinyCC on Android because "oven-sh/tinycc has no upstream
# bionic support". But TinyCC DOES have Android/Bionic support in its
# configure script (TARGETOS_ANDROID, crtbegin_so.o, /system/bin/linker64,
# aarch64-linux-android triplet). The issue is that Bun's build system
# never enables it. This patch removes the Android exclusion so TinyCC
# gets built, enabling bun:ffi callback() and linkSymbols(cc:true).
CONFIG_TS="scripts/build/config.ts"
if [ -f "$CONFIG_TS" ]; then
    if grep -q "$PATCH_MARKER" "$CONFIG_TS" 2>/dev/null; then
        echo "  [SKIP] $CONFIG_TS already patched"
    else
        echo "  [PATCH] $CONFIG_TS (enable TinyCC for Android)"
        # Remove the 'abi === "android" ||' from the tinycc exclusion
        # Before:  const tinycc = ... !((windows && arm64) || abi === "android" || freebsd);
        # After:   const tinycc = ... !((windows && arm64) || freebsd);
        sed -i "s/|| abi === \"android\" || freebsd/|| freebsd/g" "$CONFIG_TS"
        # Add marker comment on its OWN LINE (before the const) — putting it
        # inline after '??' would turn the rest of the expression into a comment.
        sed -i "/^  const tinycc = partial.tinycc/i\\  // $PATCH_MARKER: TinyCC enabled for Android (was disabled upstream)" "$CONFIG_TS"
        verify_patch "$CONFIG_TS" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 5: scripts/build/deps/tinycc.ts — add Android/Bionic defines
# =====================================================================
# Bun's tinycc.ts only sets TCC_TARGET_MACHO (macOS) and CONFIG_WIN32
# (Windows). For Android, we need TARGETOS_ANDROID + the Android paths
# (CRT files, ELF interpreter, sysroot, triplet). These defines match
# what TinyCC's ./configure --targetos=Android --cpu=arm64 generates.
TINYCC_TS="scripts/build/deps/tinycc.ts"
if [ -f "$TINYCC_TS" ]; then
    if grep -q "$PATCH_MARKER" "$TINYCC_TS" 2>/dev/null; then
        echo "  [SKIP] $TINYCC_TS already patched"
    else
        echo "  [PATCH] $TINYCC_TS (add Android defines)"
        python3 <<'PYEOF'
import re, sys

with open("scripts/build/deps/tinycc.ts", "r") as f:
    content = f.read()

# Find the line "if (cfg.windows) defines.CONFIG_WIN32 = true;"
# and add Android defines after it
old = '    if (cfg.windows) defines.CONFIG_WIN32 = true;'

new = '''    if (cfg.windows) defines.CONFIG_WIN32 = true;

    // ANDROID_TERMUX_FIX: Enable TinyCC for Android/Bionic.
    // Based on guysoft/opencode-termux's proven approach: use MINIMAL
    // defines. Don't set TARGETOS_ANDROID, CONFIG_SYSROOT, or Android
    // CRT/lib paths.
    //
    // CRITICAL: CONFIG_SELINUX=1 is the KEY define that makes JSCallback
    // work on Android. Without it, TinyCC uses tcc_malloc() + mprotect()
    // for executable memory. Android SELinux BLOCKS mprotect(PROT_EXEC)
    // on heap memory. With CONFIG_SELINUX=1, TinyCC uses mmap(PROT_EXEC)
    // directly via a tmpfile — which Android SELinux allows.
    //
    // This is why opencode-termux works: their TinyCC build (commit
    // b91835d8) has HAVE_SELINUX enabled by default. Our newer TinyCC
    // (commit 12882eee) has CONFIG_SELINUX commented out.
    if (cfg.linux && cfg.abi === "android" && cfg.arm64) {
      defines.CONFIG_SELINUX = 1;
    }'''

if old not in content:
    print("    [FAIL] could not find 'cfg.windows defines.CONFIG_WIN32' line")
    sys.exit(1)

content = content.replace(old, new, 1)

# Also add the tccrun.c patch to the patches array
old_patches = 'patches: ["patches/tinycc/tcc.h.patch"],'
new_patches = 'patches: ["patches/tinycc/tcc.h.patch", "patches/tinycc/tccrun.c.patch"],'
if old_patches in content:
    content = content.replace(old_patches, new_patches, 1)
    print("    [5a] Added CONFIG_SELINUX=1 + tccrun.c.patch to tinycc.ts")
else:
    print("    [5a] Added CONFIG_SELINUX=1 (tccrun.c.patch already in patches array?)")

with open("scripts/build/deps/tinycc.ts", "w") as f:
    f.write(content)
PYEOF
        # CRITICAL: Copy the tccrun.c.patch file into the bun source tree
        # The patches: array in tinycc.ts expects the file at
        # patches/tinycc/tccrun.c.patch RELATIVE TO THE BUN SOURCE ROOT.
        # Our patch file is in the bun-termux repo, not in bun-src.
        # We need to copy it there during patch application.
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
        mkdir -p "$BUN_SRC/patches/tinycc"
        cp "$REPO_DIR/patches/tinycc/tccrun.c.patch" "$BUN_SRC/patches/tinycc/tccrun.c.patch"
        echo "    [5b] Copied tccrun.c.patch to bun source tree"
        verify_patch "$TINYCC_TS" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 6: scripts/build/flags.ts — cross-compile CPU flag fix
# =====================================================================
FLAGS_TS="scripts/build/flags.ts"
if [ -f "$FLAGS_TS" ]; then
    if grep -q "$PATCH_MARKER" "$FLAGS_TS" 2>/dev/null; then
        echo "  [SKIP] $FLAGS_TS already patched"
    else
        echo "  [PATCH] $FLAGS_TS"
        sed -i 's/"-march=armv8-a+crc"/"-march=armv8-a"/g' "$FLAGS_TS"
        sed -i "1i // $PATCH_MARKER: simplified march flags for cross-compile" "$FLAGS_TS"
        verify_patch "$FLAGS_TS" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 7: scripts/build/tools.ts — accept NDK clang 18
# =====================================================================
TOOLS_TS="scripts/build/tools.ts"
if [ -f "$TOOLS_TS" ]; then
    if grep -q "$PATCH_MARKER" "$TOOLS_TS" 2>/dev/null; then
        echo "  [SKIP] $TOOLS_TS already patched"
    else
        echo "  [PATCH] $TOOLS_TS"
        sed -i "s/export const LLVM_VERSION = \"21.1.8\";/export const LLVM_VERSION = \"18.0.3\"; \/\/ $PATCH_MARKER: NDK r27c clang/" "$TOOLS_TS"
        sed -i "s/const LLVM_MAJOR = \"21\";/const LLVM_MAJOR = \"18\"; \/\/ $PATCH_MARKER/" "$TOOLS_TS"
        sed -i "s/const LLVM_MINOR = \"1\";/const LLVM_MINOR = \"0\"; \/\/ $PATCH_MARKER/" "$TOOLS_TS"
        sed -i "s|paths.push(\`/usr/lib/llvm-\${LLVM_MAJOR}.\${LLVM_MINOR}.0/bin\`);|paths.push(\`/usr/lib/llvm-\${LLVM_MAJOR}.\${LLVM_MINOR}.0/bin\`);\n    // $PATCH_MARKER: NDK clang\n    paths.push(\`\${process.env.ANDROID_NDK_HOME \|\| process.env.ANDROID_NDK_ROOT \|\| \"/opt/android-ndk\"}/toolchains/llvm/prebuilt/linux-x86_64/bin\`);|" "$TOOLS_TS"
        sed -i '/"-Wno-character-conversion",/d' "$FLAGS_TS" 2>/dev/null || true
        verify_patch "$TOOLS_TS" "$PATCH_MARKER" || true
    fi
fi

# =====================================================================
# PATCH 8: EncodingTables.h — remove pragma for clang 19+ warning
# =====================================================================
ENCODING_TABLES="src/jsc/bindings/EncodingTables.h"
if [ -f "$ENCODING_TABLES" ]; then
    if grep -q 'clang diagnostic ignored "-Wcharacter-conversion"' "$ENCODING_TABLES" 2>/dev/null; then
        echo "  [PATCH] $ENCODING_TABLES: remove -Wcharacter-conversion pragma"
        sed -i '/clang diagnostic ignored "-Wcharacter-conversion"/d' "$ENCODING_TABLES"
        echo "  [OK] removed pragma"
    else
        echo "  [SKIP] $ENCODING_TABLES: no pragma to remove"
    fi
fi

# =====================================================================
# PATCH 9: C++ dangling-reference fix for clang 18
# =====================================================================
echo "  [PATCH] searching for dangling reference pattern in C++ files..."
PATCHED_FILES=0
while IFS= read -r -d '' FILE; do
    if grep -q "properties.releaseData()->propertyNameVector()" "$FILE" 2>/dev/null; then
        if grep -q "_releaseData = properties.releaseData()" "$FILE" 2>/dev/null; then
            continue
        fi
        echo "    [patch] $FILE"
        perl -i -pe 's/for \(auto& (\w+) : properties\.releaseData\(\)->propertyNameVector\(\)\)/auto _releaseData = properties.releaseData(); for (auto\& $1 : _releaseData->propertyNameVector())/g' "$FILE"
        PATCHED_FILES=$((PATCHED_FILES + 1))
    fi
done < <(find src -type f \( -name "*.cpp" -o -name "*.h" \) -print0 2>/dev/null)
echo "  [OK] patched $PATCHED_FILES C++ files with dangling reference fix"

# =====================================================================
# FINAL VERIFICATION
# =====================================================================
echo ""
echo "=========================================="
echo "PATCH VERIFICATION SUMMARY"
echo "=========================================="

TOTAL_FAIL=0
for f in src/resolver/resolver.zig src/cli/run_command.zig src/exe_format/elf.zig src/standalone_graph/StandaloneModuleGraph.zig scripts/build/config.ts scripts/build/deps/tinycc.ts scripts/build/flags.ts scripts/build/tools.ts; do
    if [ -f "$f" ]; then
        if grep -q "$PATCH_MARKER" "$f" 2>/dev/null; then
            COUNT=$(grep -c "$PATCH_MARKER" "$f")
            echo "  [OK]   $f ($COUNT markers)"
        else
            echo "  [FAIL] $f — NO MARKERS FOUND"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        fi
    else
        echo "  [SKIP] $f — file not in this Bun version"
    fi
done

echo ""
if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo "=========================================="
    echo "FATAL: $TOTAL_FAIL critical patches did not apply!"
    echo "The build will NOT fix bunx. Aborting."
    echo "=========================================="
    exit 1
fi

echo "=========================================="
echo "All critical patches applied successfully."
echo "Source patches handle resolver walk (raw syscalls)."
echo "LD_PRELOAD shim handles libc calls (linkat, fopen, etc.)."
echo "=========================================="
