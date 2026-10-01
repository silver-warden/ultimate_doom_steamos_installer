# Ultimate Doom installer for SteamOS

One-shot installer that sets up a classic-id gaming library (Doom, and friends)
on a Steam Deck — engine, launcher, IWAD collection, and the DOOM Fusion
mega-WAD — so everything runs nicely in both Desktop and Gaming mode.

## What it does

1. **Preflight** — checks for `flatpak`, `curl`, `python3`, `unzip`, and the
   Flathub remote.
2. **UZDoom** — installs the [`org.zdoom.UZDoom`][uzdoom-flathub] Flatpak
   (system-wide, falling back to `--user`).
3. **DoomRunner** — downloads the latest [DoomRunner][doomrunner] Linux
   AppImage into the Doom root (reuses a matching one already there).
4. **Engine wrapper** — `~/.local/bin/uzdoom` runs the Flatpak like a native
   binary, and sets gamescope's `GAMESCOPE_COMPOSITE_FORCE` to work around the
   Steam Gaming mode scanout glitch ([gamescope#1368][gamescope-1368]).
5. **Doom root** — creates the folder layout shown below (asks for the
   location; default `~/Games/Doom`).
6. **Sandbox access** — one recursive Flatpak override exposes the whole Doom
   root to UZDoom and sets `DOWADPATH`/`DOOMWADPATH` to the `iwads` folder.
   Flatseal is installed for optional GUI review.
7. **IWADs** — hash-scans your Steam libraries and `iwads/` for the official
   Doom wads (including the KEX re-release files for widescreen gfx) and
   stages them for WadFusion.
8. **Extras** — stages owned **Heretic / Hexen / Strife / Chex Quest** wads
   found in Steam, and asks whether to download the free ones:
   **[Freedoom][freedoom] Phase 1 + 2** and **[Blasphemer][blasphemer]**
   (a free Heretic total conversion).
9. **DOOM Fusion** — runs [WadFusion][wadfusion] to build
   `doom_fusion.ipk3` (+ widescreen gfx pk3) into `iwads/`.
 10. **DoomRunner config** — seeds `options.json` with the UZDoom engine,
     the `iwads`/`mods` directories, the "DOOM Fusion" preset, and one preset
     per other game whose IWAD is present (Heretic, Hexen, Strife, Chex Quest,
     Freedoom 1/2, Blasphemer), with per-preset config/save-dir isolation
     enabled so each game keeps its own settings and saves. Plus **one preset
     per subfolder of `mods/Mods`**, bundling that folder's top-level
     pk3/wad/deh files (loads in alphabetical order; pick the IWAD once in
     the GUI) — ready-made presets so handheld users never have to assemble
     a mod stack by hand. Existing presets are kept as-is, so curated
     presets survive re-runs; delete one you do not want and it only comes
     back if you re-run the script.
 11. **Steam shortcut** — adds DoomRunner to the Steam library as a
     non-Steam game (binary `shortcuts.vdf`, every user profile) and installs
     the bundled `steam_art/` grid art (hero, logo, capsules, icon). If Steam
     is running while the shortcut still needs creating, it prints a hint
     (Steam rewrites the vdf on exit) instead of writing.

The script is **idempotent**: re-run it any time to update or repair.

## Install

### Recommended: git clone

```console
$ git clone https://github.com/silver-warden/ultimate_doom_steamos_installer.git
$ cd ultimate_doom_steamos_installer
$ ./install_doom.sh
```

Updates are then just `git pull && ./install_doom.sh` — the script itself
re-checks and upgrades DoomRunner/WadFusion/Freedoom and rebuilds DOOM
Fusion where needed.

### Alternative: download the zip

Grab "Code → Download zip" from GitHub, unpack anywhere and run
`./install_doom.sh` from there. Updating means re-downloading the zip —
or just swapping in the new script: the installer is a **single
self-contained file**; even the optional Steam grid art is fetched from
the repo when no `steam_art/` folder sits next to the script:

```console
$ curl -fsSLo install_doom.sh https://raw.githubusercontent.com/silver-warden/ultimate_doom_steamos_installer/main/install_doom.sh
$ chmod +x install_doom.sh && ./install_doom.sh
```

A `curl ... | bash` one-liner also works for a single run — but that
means executing before reading, which the disclaimer below advises
against, so it is not recommended.

## Usage

```console
$ ./install_doom.sh                    # interactive
$ ./install_doom.sh -y                 # defaults everywhere, extras declined
$ ./install_doom.sh -y --extras        # non-interactive, also grab Freedoom + Blasphemer
$ ./install_doom.sh --root ~/games/Doom --force
```

| Flag | Meaning |
| --- | --- |
| `-y`, `--yes` | non-interactive, accept defaults (optional downloads declined) |
| `--root DIR` | Doom root folder (skips the prompt) |
| `--force` | re-download DoomRunner/WadFusion/Freedoom/Blasphemer and rebuild the ipk3 |
| `--extras` | auto-accept the Freedoom/Blasphemer prompts |
| `--no-extras` | auto-decline them (the default under `-y`) |

## Supported games

| Game | Source |
| --- | --- |
| Doom / Ultimate Doom, DOOM II, TNT, Plutonia, Sigil… | owned on Steam → hash-staged into `iwads/` + DOOM Fusion |
| Heretic (+ Serpent Riders), Hexen (+ Deathkings), Strife, Chex Quest | owned on Steam → staged under UZDoom's canonical names |
| Freedoom Phase 1 + 2 | free download ([freedoom.github.io][freedoom]) — optional prompt |
| Blasphemer | free download ([github.com/Blasphemer][blasphemer]) — optional prompt |

UZDoom identifies Heretic/Hexen/Strife/Chex by filename (`heretic.wad`,
`hexen.wad`, `strife1.wad`/`sve.wad`, `chex.wad`/`chex3.wad`) — any version
works, remasters included.

## Folder layout

Everything lives under one root folder (default `~/Games/Doom`):

```
Doom/
├── DoomRunner-<ver>-Linux-x86_64.AppImage   # the launcher
├── iwads/                                    # IWADs + doom_fusion.ipk3 (managed by the script)
├── mods/
│   ├── Mods/                                 # gameplay mods (.pk3/.ipk3/...)
│   ├── Maps/                                 # standalone map wads
│   ├── Graphics/                             # graphics replacement mods
│   ├── Sound/                                # sound/music replacement mods
│   ├── Music/                                # custom music packs
│   └── Performance/                          # performance tweak mods
└── tools/                                    # WadFusion working copy
```

Anything deeper inside `mods/` is up to you — the script only creates those
six top-level categories and never touches their contents. DoomRunner is
preconfigured to browse `mods/Mods` and `mods/Maps`; add the others to
DoomRunner's mod paths as you like (UZDoom sees the whole tree anyway).

## Requirements / portability

Works on **any x86_64 Linux**, not just SteamOS — but these things must exist:

- `flatpak` with Flathub enabled (the only hard, SteamOS-adjacent dependency)
- `curl`, `python3`, `unzip`
- AppImage support for DoomRunner: `libfuse2` (or run it via
  `--appimage-extract-and-run` on distros that dropped FUSE 2)
- Steam installed somewhere, if you want owned wads auto-detected (the script
  looks in `~/.local/share/Steam`, `~/.steam`, `/run/media/*` and `/media/*/*`)

The SteamOS-specific bits degrade gracefully elsewhere: the SteamOS check is
only a warning, and the gamescope `xprop` workaround is a no-op outside the
Deck. On non-Deck machines just pick your own `--root` (the default is
`$HOME/Games/Doom`).

## Manual next steps

- Launch DoomRunner by double-clicking the AppImage; it is also added to the
  Steam library automatically — restart Steam (switching to Gaming mode does
  it) to see it. If Steam was running during the install, quit it and re-run
  the script once to create the shortcut.
- Review UZDoom permissions any time with Flatseal.

## Acknowledgements

This installer is nothing more than glue around the work of others — thanks
to all of them:

| Project | For |
| --- | --- |
| [UZDoom][uzdoom-gh] | the engine (continuation of [GZDoom][gzdoom] / ZDoom) |
| [DoomRunner][doomrunner] by Youda008 | the game launcher / mod manager |
| [WadFusion][wadfusion] by Owlet7 | DOOM Fusion, the ultimate Doom IWAD |
| [Freedoom][freedoom-gh] | the free Doom-compatible IWADs (Phase 1 + 2) |
| [Blasphemer][blasphemer-gh] | the free Heretic total conversion |
| [Flatseal][flatseal] | GUI to review Flatpak permissions |
| [gamescope][gamescope] | Steam Deck compositor (the [scanout workaround][gamescope-1368] lives in the `uzdoom` wrapper) |

And of course id Software, for Doom, DOOM II, Heretic, Hexen and the rest of
the classics this all plays host to.

## License

The installer and docs of this repository are licensed under the
[GNU GPL v3.0][gpl] (or, at your option, any later version) — use, study,
modify and share freely, keeping derivatives open under the same terms;
see [LICENSE](LICENSE). The grid art in `steam_art/` is third-party
community artwork of unknown provenance and explicitly excluded (see its
README). Third-party tools this script downloads (UZDoom, DoomRunner,
WadFusion — all GPL-family) are likewise not covered: they reach you under
their own terms, as do the game assets you stage.

## Disclaimer

This repository was fully coded using AI. It is provided **as is**, with no
warranties of any kind, without even the implied warranty of fitness for a
particular purpose — use it at your own risk. It downloads and runs
third-party binaries and edits Steam and launcher config files on your
machine; read the script before running it, and keep the `.bak` backups it
creates.

[gpl]: https://www.gnu.org/licenses/gpl-3.0.html
[uzdoom-flathub]: https://flathub.org/apps/org.zdoom.UZDoom
[uzdoom-gh]: https://github.com/UZDoom/UZDoom
[gzdoom]: https://github.com/ZDoom/gzdoom
[doomrunner]: https://github.com/Youda008/DoomRunner
[wadfusion]: https://github.com/Owlet7/wadfusion
[freedoom]: https://freedoom.github.io/download.html
[freedoom-gh]: https://github.com/freedoom/freedoom
[blasphemer]: https://github.com/Blasphemer/blasphemer/releases
[blasphemer-gh]: https://github.com/Blasphemer/blasphemer
[flatseal]: https://github.com/tchx84/Flatseal
[gamescope]: https://github.com/ValveSoftware/gamescope
[gamescope-1368]: https://github.com/ValveSoftware/gamescope/issues/1368
