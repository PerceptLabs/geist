# Geist

A single-file autonomous AI agent. One binary, six operating systems, two architectures.

Geist packages [NullClaw](https://github.com/nullclaw/nullclaw) (a 678KB Zig-based AI agent framework) with [Cosmopolitan Libc](https://github.com/jart/cosmopolitan) to produce `geist.com` — an [Actually Portable Executable](https://justine.lol/ape.html) that runs unmodified on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD across both x86_64 and aarch64.

## Supported Platforms

| OS | x86_64 | aarch64 |
|----|--------|---------|
| Linux | Yes | Yes |
| macOS | Yes | Yes (Apple Silicon) |
| Windows | Yes | — |
| FreeBSD | Yes | Yes |
| OpenBSD | Yes | Yes |
| NetBSD | Yes | Yes |

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/PerceptLabs/geist/main/install.sh | sh

# Set up your API key and provider
geist onboard

# Start chatting
geist agent -m "Hello, world"
```

## Building from Source

### Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) (exact version required)
- [cosmocc](https://cosmo.zip/pub/cosmocc/) (Cosmopolitan C compiler toolchain)
- git, curl

### Build

```bash
git clone https://github.com/PerceptLabs/geist.git
cd geist
./build-geist.sh
```

This produces `dist/geist.com` (fat APE binary) along with per-architecture ELF binaries in `dist/`.

### Test

```bash
./test-geist.sh
```

For the full build guide including architecture details, build phases, and troubleshooting, see [CLAUDE.md](CLAUDE.md).

## Project Structure

```
geist/
├── CLAUDE.md              # Comprehensive build guide
├── README.md              # This file
├── build-geist.sh         # Master build script
├── test-geist.sh          # Test script
├── install.sh             # User-facing installer
├── patches/               # NullClaw patches for Geist builds
│   └── *.patch
└── dist/                  # Build output (gitignored)
    ├── geist.com          # Fat APE (x86_64 + aarch64)
    ├── geist-linux-x86_64
    ├── geist-linux-aarch64
    └── checksums.txt
```

## How It Works

NullClaw is compiled with Zig 0.15.2 and linked against Cosmopolitan Libc instead of musl. Cosmopolitan provides the same POSIX function signatures (`open`, `read`, `write`, `socket`, etc.) but translates them to the host OS at runtime. The x86_64 and aarch64 ELF binaries are then combined via `apelink` into a single fat APE binary.

The agent uses `curl` as a subprocess for HTTP — the host system must have `curl` installed.

## License

MIT — same as NullClaw.

## Links

- [NullClaw](https://github.com/nullclaw/nullclaw) — the agent runtime
- [Cosmopolitan Libc](https://github.com/jart/cosmopolitan) — the universal libc
- [Actually Portable Executable](https://justine.lol/ape.html) — the binary format
