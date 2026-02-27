# Overclocked Lynx Paws - Cyberpunk 2077 Mod

Adds wall running, wall climbing, wall kick chaining, and Kerenzikov integration
to Cyberpunk 2077. Installable and documented via
[NexusMods](https://www.nexusmods.com/cyberpunk2077/mods/27692).

## Development Setup

The repo mirrors the Cyberpunk 2077 directory structure. A
[justfile](https://github.com/casey/just) is provided to symlink the mod into
your game install and build release archives.

### Prerequisites

- [just](https://github.com/casey/just) — task runner
- [WolvenKit CLI](https://wiki.redmodding.org/wolvenkit/wolvenkit-cli) — archive
packing (requires .NET 8 runtime)
  - **Linux (Arch)**: `yay -S wolvenkit-cli-bin dotnet-runtime-8.0`
  - **Linux (other)**: Download from [WolvenKit
  releases](https://github.com/WolvenKit/WolvenKit/releases), install [.NET
  8](https://dotnet.microsoft.com/download/dotnet/8.0)
  - **Windows**: Download from [WolvenKit
  releases](https://github.com/WolvenKit/WolvenKit/releases), ensure
  `wolvenkit-cli` is on your PATH
  - **macOS**: WolvenKit CLI is Windows/Linux only — use a VM or WSL

### Loading Development Code As An Active Mod

1. Make sure you do not have the actual mod archive installed.
2. Copy `.justfile.local.example` to `.justfile.local`
2. Edit `.justfile.local` and set the `game` variable to your Cyberpunk 2077
install path

```bash
   cp .justfile.local.example .justfile.local
   # Edit .justfile.local with your game path
   # Create symlinks from game directory to repo just link
   # Remove symlinks from game directory just unlink
```

This symlinks the CET mod, Redscript, TweakDB overrides, and ArchiveXL
localization into the game directory. `.justfile.local` is gitignored so your
local paths won't affect the repo.

CET scripts can be hot-reloaded in-game. Redscript, ArchiveXL, and localization
changes require a full game restart.

### Rebuilding the localization archive

The `WallRunning.archive` contains localization strings for the Overclocked Lynx
Paws cyberware name and description. It must be rebuilt whenever the
localization text changes or after a major game update.

Requires: [WolvenKit CLI](https://wiki.redmodding.org/wolvenkit/wolvenkit-cli)
(`wolvenkit-cli-bin` on AUR) and `dotnet-runtime-8.0`.

1. Edit the source JSON at `archive/pc/mod/localization-src/en-us.json.json`
2. Run `just archive` (or `just build` to also package the release zip)
