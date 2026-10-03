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
  `/tmp/.mount_*` dir (see doc §4). `ask_root` therefore `cd`s into the root
  and takes `pwd` before anything is derived from it.
- Config edits are **merge + repair**, never replace: seed the full schema the
  GUI writes (partial presets trigger missing-key warning dialogs) **including
  a `version` stamp set to the installed DoomRunner tag** — a file without
  `version` is parsed as the pre-1.7 format: engine list ignored, "engine was
  removed from the list" dialogs, deletion persisted on exit (see doc §2) —
  match existing presets by `name` and never overwrite them. Policy booleans
  (`auto_update`, `search_subdirs`, `use_preset_name_as_*`) are seeded **only
  when the key is absent**, and `default_engine`/`selected_preset` are only
  claimed when empty or dead — a re-run must not revert user GUI toggles
  (doc §2).
- **Never rewrite `options.json` while DoomRunner runs, or `shortcuts.vdf`
  while Steam runs** — both keep it in memory and clobber the file on exit.
- Binary VDF: the whole file is a root section closed by a final `0x08`; fail
  loudly on unknown value types instead of rewriting blind.
- The non-Steam appid is **per-profile data**: grid art and the entry `icon`
  are keyed by each profile's own matched appid, never by one global id.
  While Steam runs, adds are impossible — count them as `skipped` and exit 3,
  don't print a success line.
- Everything must stay idempotent (re-run = repair, no duplicates) and writes
  go through temp file + atomic rename, with a timestamped `.bak` alongside.
- Downloads use `.part` + rename and register temp dirs/files in `CLEANUP`
  (an `EXIT` trap) — an abort via `set -e`/`die` must not leak them.

## Testing

- Syntax: `bash -n install_doom.sh`
- No test suite; functions are testable in isolation — `source ./install_doom.sh`
  (guarded, runs nothing) then call e.g. `seed_doomrunner_config` with env
  overrides: `ROOT`, `CFG`, `CFG_DIR` (config seeding) or `STEAM_DIR`,
  `RUNNER_BIN`, `ART_DIR`, `WRITE` (shortcut step). Point them at sandbox
  copies under `/tmp` first — e.g. copy a real `shortcuts.vdf` and verify
  parse/serialize round-trips byte-identity before trusting a change.
