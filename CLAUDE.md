# CLAUDE.md — Geist Build Project

## What This Project Is

Geist is an autonomous AI agent that ships as a single portable file (`geist.com`). It is built by compiling NullClaw (an existing Zig-based agent framework) against Cosmopolitan Libc so the resulting binary runs on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD from a single build.

**NullClaw** is the agent runtime. **Cosmopolitan** is the universal libc. **Geist** is the product — the magic file.

## Architecture

```
NullClaw (Zig source, unmodified or minimally modified)
    ↓ compiled with Zig 0.15.2 (the exact version NullClaw requires)
    ↓ linked against cosmopolitan.a (instead of Zig's bundled musl)
    ↓ produces ELF binaries for x86_64 and aarch64
    ↓ combined via apelink (Cosmopolitan's fat binary linker)
    ↓ produces geist.com (single file, runs on 6+ OSes, both architectures)
```

The key insight: NullClaw's source code should NOT need significant changes. Cosmopolitan exports the same POSIX function signatures as musl (`open`, `read`, `write`, `socket`, etc.) but translates them to the host OS at runtime. We swap which libc NullClaw links against, not how NullClaw's code works.

## Repository Layout

```
geist/
├── CLAUDE.md                    # This file
├── nullclaw/                    # Git clone of nullclaw/nullclaw (submodule or clone)
├── cosmo/                       # Extracted cosmocc toolchain
├── patches/                     # Any patches needed for NullClaw to build with Cosmo
│   └── *.patch                  # Minimal, documented patches
├── build-geist.sh               # Master build script
├── test-geist.sh                # Test script
└── dist/
    ├── geist.com                # Fat APE (x86_64 + aarch64)
    ├── geist-linux-x86_64       # Standalone Linux x86_64
    ├── geist-linux-aarch64      # Standalone Linux aarch64
    └── checksums.txt
```

## Tools Available

* Zig 0.15.2 at `/home/user/zig/zig` (exact version NullClaw requires)
* cosmocc at `/home/user/cosmo/bin/cosmocc`
* apelink at `/home/user/cosmo/bin/apelink`
* APE loader registered in binfmt_misc
* NullClaw source at `/home/user/nullclaw/`
* Full network access for any additional downloads

## Phase 0: Verify Baseline

**Goal**: Confirm NullClaw builds and runs normally before we touch anything.

### Task 0.1 — Normal NullClaw Build

```bash
cd /home/user/nullclaw
zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite
ls -lh zig-out/bin/nullclaw
```

Expected: ~678KB binary. If this fails, fix Zig version or dependency issues first.

### Task 0.2 — Verify It Runs

```bash
./zig-out/bin/nullclaw --help
./zig-out/bin/nullclaw version
```

Should print help and version info without errors.

### Task 0.3 — Run Tests

```bash
zig build test --summary all 2>&1 | tail -50
```

Note how many tests pass. This is our baseline. We need the Cosmo build to pass the same tests.

### Task 0.4 — Understand the Build

Read `build.zig` carefully. Identify:

* How the main executable is declared (`b.addExecutable(...)`)
* How SQLite is compiled (vendored C source via `b.dependency("sqlite3", ...)`)
* What features are enabled by default
* Whether `-lc` is explicitly linked anywhere
* What the linker configuration looks like

Document your findings before proceeding.

## Phase 1: Cosmo Link Spike

**Goal**: Get NullClaw to compile and link against `cosmopolitan.a`. This is the critical experiment. We want to find out what breaks.

### Task 1.1 — Examine Cosmo's Toolchain

```bash
ls /home/user/cosmo/bin/
ls /home/user/cosmo/include/ | head -20
nm /home/user/cosmo/lib/cosmopolitan.a 2>/dev/null | grep " T " | head -30
# Or find where cosmopolitan.a lives:
find /home/user/cosmo -name "cosmopolitan.a" -o -name "libc.a" 2>/dev/null
```

Understand the Cosmo toolchain layout:

* Where are the headers?
* Where is `cosmopolitan.a`?
* What symbols does it export?

Verify critical symbols exist:

```bash
nm /path/to/cosmopolitan.a | grep -E "T (open|read|write|close|socket|connect|send|recv|fork|exec|pipe|waitpid|getenv|malloc|free|sqlite3_open)" | head -20
```

### Task 1.2 — Test Cosmo with a Minimal Zig Program

Before touching NullClaw, verify Zig + Cosmo works at all.

Create a minimal test:

```zig
// test_cosmo.zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello from Zig + Cosmo!\n", .{});
}
```

Try to compile it linking against Cosmo:

```bash
# Approach A: Use cosmocc as the C compiler backend for Zig
zig build-exe test_cosmo.zig -target x86_64-linux -lc \
  --sysroot /home/user/cosmo \
  -I /home/user/cosmo/include \
  -L /home/user/cosmo/lib

# Approach B: Compile to object, link with cosmocc
zig build-obj test_cosmo.zig -target x86_64-linux
cosmocc -o test_cosmo.com test_cosmo.o

# Approach C: Use Zig's C compiler integration
zig build-exe test_cosmo.zig -target x86_64-linux \
  -cflags -nostdinc -- \
  -I /home/user/cosmo/include \
  -L /home/user/cosmo/lib \
  -lcosmopolitan
```

At least one of these approaches should work. If none do, investigate:

* Does Zig's `-lc` flag accept an external libc?
* Can we override Zig's libc selection via `build.zig` configuration?
* Does `zig cc` (Zig as a C compiler) work with Cosmo's headers?
* Check the Ziggit APE thread approach: compile per-arch, apelink after

The Ziggit approach (most likely to work):

```bash
# Build normal Linux ELF binaries
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux -Dengines=base,sqlite
cp zig-out/bin/nullclaw nullclaw-x86_64

zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux -Dengines=base,sqlite
cp zig-out/bin/nullclaw nullclaw-aarch64

# apelink them into a fat binary
/home/user/cosmo/bin/apelink \
  -l /home/user/cosmo/bin/ape-x86_64.elf \
  -l /home/user/cosmo/bin/ape-aarch64.elf \
  -M /home/user/cosmo/bin/ape-m1.c \
  -o geist.com \
  nullclaw-x86_64 \
  nullclaw-aarch64

./geist.com --help
```

**IMPORTANT**: The Ziggit approach produces a fat binary that works on Linux x86_64 + aarch64. It does NOT give cross-OS portability (macOS/Windows) because Zig's std bakes in Linux constants. This is the "packaging wrapper" approach — useful but not the full vision.

To get true cross-OS, we need the libc swap. Try the libc swap first. If it fails after reasonable effort, fall back to the Ziggit approach and document what went wrong.

### Task 1.3 — Modify NullClaw's build.zig for Cosmo

If Task 1.2 established how Zig + Cosmo links, apply that to NullClaw's `build.zig`.

The changes should be minimal. Look for where the executable is configured and add Cosmo's include/lib paths. Key things to configure:

1. Add Cosmo's include directory to the C include path (for vendored SQLite compilation)
2. Add Cosmo's library directory to the linker search path
3. Link against `cosmopolitan.a` (or however Cosmo's symbols are provided)
4. Disable hardware features that use raw Linux syscalls:
   * i2c tools (`src/tools/i2c.zig`) — uses `std.os.linux.syscall3` for ioctl
   * spi tools (`src/tools/spi.zig`) — same
   * These should be behind feature flags already

Keep a patch file of every change you make to NullClaw:

```bash
cd /home/user/nullclaw
git diff > /home/user/geist/patches/01-cosmo-build.patch
```

### Task 1.4 — Build and Catalog Errors

Build NullClaw with Cosmo linking:

```bash
cd /home/user/nullclaw
zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite 2>&1 | tee /tmp/cosmo-build.log
```

Catalog EVERY error. Categorize them:

* **Missing symbols** — function not in `cosmopolitan.a` (need to check what Cosmo provides)
* **Constant mismatches** — Zig's std has a Linux value, Cosmo expects extern
* **Type mismatches** — struct layout differs between Zig's std and Cosmo
* **Raw syscalls** — code bypasses libc (we identified ~10, mostly hardware)
* **Compiler flags** — Zig and cosmocc disagree on something

For each error, document:

1. The exact error message
2. Which source file
3. What the fix should be (or if it's a dead end)

### Task 1.5 — Fix and Iterate

For each error, apply the MINIMAL fix. Prefer:

1. Build system configuration (best — no source changes)
2. Feature flags to disable problematic code (good — uses existing mechanisms)
3. Conditional compilation `if (builtin.os.tag == .linux)` guards (ok — small source change)
4. Actual code changes (last resort — document why)

After each fix, rebuild and check if the error count decreased.

Save patches after each fix round:

```bash
git diff > /home/user/geist/patches/02-fix-round-N.patch
```

## Phase 2: Working Binary

**Goal**: A NullClaw binary linked against Cosmo that runs basic commands.

### Task 2.1 — Smoke Test

```bash
./geist.com version
./geist.com --help
./geist.com status
./geist.com doctor
```

Each of these should work. `doctor` will complain about missing config — that's fine.

### Task 2.2 — Onboarding Test

```bash
./geist.com onboard --api-key test-key-123 --provider openrouter
```

This should create a config file. It will fail to validate the API key (fake key) but the config creation flow should work.

### Task 2.3 — Chat Test (requires real API key)

If you have an API key:

```bash
export OPENROUTER_API_KEY=sk-or-...
./geist.com onboard --api-key $OPENROUTER_API_KEY --provider openrouter
./geist.com agent -m "Say hello in exactly three words"
```

This exercises the full pipeline: config loading, provider dispatch, HTTP via curl subprocess, response parsing, output.

### Task 2.4 — Run Test Suite

```bash
zig build test --summary all 2>&1 | tee /tmp/cosmo-test.log
```

Compare against the baseline from Phase 0. Document any test regressions.

## Phase 3: Fat APE Binary

**Goal**: Produce `geist.com` that contains both x86_64 and aarch64 in one file.

### Task 3.1 — Build Both Architectures

```bash
cd /home/user/nullclaw

# x86_64
zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite -Dtarget=x86_64-linux
cp zig-out/bin/nullclaw /home/user/geist/dist/geist-linux-x86_64

# aarch64
zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite -Dtarget=aarch64-linux
cp zig-out/bin/nullclaw /home/user/geist/dist/geist-linux-aarch64
```

Note: aarch64 cross-compilation might need additional Cosmo setup. If it fails, document the error and proceed with x86_64 only.

### Task 3.2 — apelink

```bash
/home/user/cosmo/bin/apelink \
  -l /home/user/cosmo/bin/ape-x86_64.elf \
  -l /home/user/cosmo/bin/ape-aarch64.elf \
  -M /home/user/cosmo/bin/ape-m1.c \
  -o /home/user/geist/dist/geist.com \
  /home/user/geist/dist/geist-linux-x86_64 \
  /home/user/geist/dist/geist-linux-aarch64
```

### Task 3.3 — Verify Fat Binary

```bash
ls -lh /home/user/geist/dist/geist.com
file /home/user/geist/dist/geist.com
./geist.com version
./geist.com --help
```

Report the binary size. Target is under 2MB (NullClaw is 678KB per arch, APE overhead ~200KB).

### Task 3.4 — Generate Checksums

```bash
cd /home/user/geist/dist
sha256sum geist.com geist-linux-x86_64 geist-linux-aarch64 > checksums.txt
cat checksums.txt
```

## Phase 4: Rename and Brand

**Goal**: The binary identifies itself as "Geist" not "NullClaw".

### Task 4.1 — Identify Branding Strings

```bash
grep -rn "nullclaw\|NullClaw\|NULLCLAW" /home/user/nullclaw/src/ --include="*.zig" | grep -i "version\|name\|brand\|banner\|welcome\|logo" | head -20
```

### Task 4.2 — Minimal Branding Patch

Change the binary name and version strings. Find where the CLI name is set (likely in `main.zig` clap/arg configuration) and the version string (likely in `version.zig`).

The changes should be:

* Binary name: `geist` (not `nullclaw`)
* Version: `geist v0.1.0 (powered by NullClaw + Cosmopolitan)`
* Config directory: `~/.config/geist/` (not `~/.nullclaw/`)
* Help text: references to "Geist" instead of "NullClaw"

Keep it minimal. We're not forking the project — we're repackaging it. Upstream compatibility matters.

Save patch:

```bash
cd /home/user/nullclaw
git diff > /home/user/geist/patches/03-geist-branding.patch
```

### Task 4.3 — Rebuild and Verify

```bash
# Rebuild with branding
zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite
./zig-out/bin/geist version
./zig-out/bin/geist --help
```

Should say "Geist" not "NullClaw".

## Phase 5: Build Script and CI

**Goal**: One-command build that produces `geist.com`.

### Task 5.1 — Create build-geist.sh

Write a script that:

1. Verifies Zig 0.15.2 and cosmocc are installed
2. Clones or updates NullClaw
3. Applies patches from `patches/`
4. Builds x86_64 and aarch64
5. Runs apelink
6. Generates checksums
7. Reports binary sizes and test results

### Task 5.2 — Create test-geist.sh

Write a script that:

1. Runs `geist.com version`
2. Runs `geist.com --help`
3. Runs `geist.com status`
4. Runs `geist.com doctor`
5. Runs the Zig test suite
6. Reports pass/fail summary

### Task 5.3 — Create install.sh

Write a user-facing install script:

```bash
#!/bin/bash
# curl -fsSL https://geist.atua.dev/install.sh | bash
set -e

GEIST_VERSION="0.1.0"
ARCH=$(uname -m)
OS=$(uname -s)

# ... detect platform, download correct binary or geist.com
# ... place in ~/.local/bin or /usr/local/bin
# ... run geist onboard
```

## Phase 6: Cross-OS Testing (if libc swap worked)

Only relevant if Phase 1 achieved true Cosmo-native linking (not just apelink wrapping).

### Task 6.1 — Test on Linux x86_64

```bash
./geist.com version  # Should work (we're on Linux)
```

### Task 6.2 — Test on Other Platforms

These require manual testing or CI with macOS/Windows runners:

* macOS Intel: Copy `geist.com`, run it
* macOS Apple Silicon: Copy `geist.com`, run it (APE handles this)
* Windows: Rename to `geist.exe` or use APE loader
* FreeBSD: Run `geist.com`

Document which platforms work and which don't.

## Key Constraints

1. **Zig version must be exactly 0.15.2**. NullClaw does not build on other versions.
2. **Minimize patches to NullClaw**. Every patch is maintenance debt. Prefer build config over source changes.
3. **curl must be available at runtime**. NullClaw does HTTP via curl subprocess, not Zig's HTTP client. On Cosmo, this means the host system needs curl installed (or we bundle a Cosmo-built curl).
4. **SQLite is vendored as C source**. It compiles with whatever C compiler we point at it. This should work with cosmocc or Zig's C compilation.
5. **Hardware features (I2C, SPI) use raw Linux syscalls**. Disable them for Geist builds. They're for embedded/IoT, not desktop agents.
6. **NullClaw's config is JSON, not TOML**. The Geist spec says TOML. For v1, accept JSON. Config format is a future concern.

## Known OS Interaction Surface (from source audit)

| Pattern | Count | Risk for Cosmo | Notes |
|---------|-------|-----------------|-------|
| `std.posix.*` | 52 calls | LOW | Routes through libc with `-lc` |
| `std.os.linux.*` | 10 calls | 8 HARDWARE-ONLY | `i2c.zig`, `spi.zig` — disable via features |
| `std.os.linux.getpid` | 2 calls | TRIVIAL | Replace with libc `getpid()` or ifdef |
| `std.os.linux.syscall2(.statfs)` | 1 call | LOW | In `sqlite.zig` WAL detection — can fallback |
| `std.c.*` | 2 calls | NONE | Already goes through libc |
| `std.os.windows.*` | 18 calls | NONE | Not compiled for Linux target |
| `builtin.os.tag` checks | 125 | NONE | Compile as Linux — Cosmo expects Linux ABI |
| HTTP | ALL via curl | RUNTIME DEP | `curl` must be on PATH |

## Success Criteria

* [ ] `geist.com version` runs and prints version info
* [ ] `geist.com --help` shows help text
* [ ] `geist.com onboard` creates config directory and file
* [ ] `geist.com agent -m "hello"` sends a message to an LLM and prints the response (requires API key)
* [ ] Binary size under 2MB (per-arch), under 4MB (fat APE)
* [ ] Patches to NullClaw are fewer than 100 lines total
* [ ] All patches are saved as `.patch` files in `patches/`
* [ ] `build-geist.sh` produces `geist.com` in one command

## What To Do If Things Go Wrong

**If Zig refuses to link against cosmopolitan.a**: Fall back to the Ziggit approach — build normal Linux ELF binaries with Zig's bundled musl, then apelink them. This gives Linux portability only, not cross-OS. Document the blockers for the full Cosmo approach.

**If apelink rejects Zig's output**: Zig may produce ELF binaries that apelink can't consume. Check if Zig's output is a static PIE (apelink may need non-PIE). Try `zig build -Doptimize=ReleaseSmall` with `-fno-PIE` or equivalent Zig flags.

**If NullClaw crashes at runtime but builds fine**: It's probably a constants mismatch. Run with strace to see which syscall is getting wrong arguments:

```bash
strace -f ./geist.com version 2>&1 | grep -E "open|socket|connect" | head -20
```

**If SQLite fails to compile**: The vendored `sqlite3.c` needs a C compiler. Zig has one built in. If it fails with Cosmo headers, try compiling `sqlite3.c` separately with cosmocc and linking the `.o` file.

**If tests fail**: Categorize failures. Network tests will fail if curl behavior differs. Filesystem tests should pass. Memory tests depend on SQLite. Focus on getting the core agent loop working first.

## Reference Links

* NullClaw repo: https://github.com/nullclaw/nullclaw
* Cosmopolitan: https://github.com/jart/cosmopolitan
* cosmocc docs: https://github.com/jart/cosmopolitan/blob/master/tool/cosmocc/README.md
* Zig + APE thread: https://ziggit.dev/t/actually-portable-executable-ape-with-zig/5497
* Rust + APE example: https://github.com/ahgamut/rust-ape-example
