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
   location; default `~/juegos/Doom`).
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
    Freedoom 1/2, Blasphemer).

The script is **idempotent**: re-run it any time to update or repair.

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

Everything lives under one root folder (default `~/juegos/Doom`):

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
`$HOME/juegos/Doom`).

## Manual next steps

- Launch DoomRunner by double-clicking the AppImage; to play in Gaming mode,
  *Add a Game* → browse to the AppImage.
- Review UZDoom permissions any time with Flatseal.

[uzdoom-flathub]: https://flathub.org/apps/org.zdoom.UZDoom
[doomrunner]: https://github.com/Youda008/DoomRunner
[wadfusion]: https://github.com/Owlet7/wadfusion
[freedoom]: https://freedoom.github.io/download.html
[blasphemer]: https://github.com/Blasphemer/blasphemer/releases
[gamescope-1368]: https://github.com/ValveSoftware/gamescope/issues/1368
