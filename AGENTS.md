# AGENTS.md

One-shot bash installer (`install_doom.sh`) that sets up UZDoom (Flatpak) +
DoomRunner (AppImage) + WadFusion + IWAD collection on SteamOS, including
DoomRunner config seeding and Steam non-Steam game shortcuts.

## Read this first

- **[docs/doomrunner-config.md](docs/doomrunner-config.md)** — reverse-engineered
  knowledge of the DoomRunner `options.json` and Steam `shortcuts.vdf` formats,
  verified against DoomRunner v1.9.2 sources with `file:line` refs. Read it
  before touching `seed_doomrunner_config` or `add_steam_shortcut`.

## Hard rules (learned the painful way)

- All paths written into configs must be **absolute** — DoomRunner absolutizes
  relative paths against its CWD, which for the AppImage is an ephemeral
  `/tmp/.mount_*` dir (see doc §4).
- Config edits are **merge + repair**, never replace: seed the full schema the
  GUI writes (partial presets trigger missing-key warning dialogs), match
  existing presets by `name` and never overwrite them.
- **Never rewrite `options.json` while DoomRunner runs, or `shortcuts.vdf`
  while Steam runs** — both keep it in memory and clobber the file on exit.
- Binary VDF: the whole file is a root section closed by a final `0x08`; fail
  loudly on unknown value types instead of rewriting blind.
- Everything must stay idempotent (re-run = repair, no duplicates) and writes
  go through temp file + atomic rename, with a timestamped `.bak` alongside.

## Testing

- Syntax: `bash -n install_doom.sh`
- No test suite; functions are testable in isolation — `source ./install_doom.sh`
  (guarded, runs nothing) then call e.g. `seed_doomrunner_config` with env
  overrides: `ROOT`, `CFG`, `CFG_DIR` (config seeding) or `STEAM_DIR`,
  `RUNNER_BIN`, `ART_DIR`, `WRITE` (shortcut step). Point them at sandbox
  copies under `/tmp` first — e.g. copy a real `shortcuts.vdf` and verify
  parse/serialize round-trips byte-identity before trusting a change.
