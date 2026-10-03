# DoomRunner & Steam config notes

Everything we reverse-engineered while building this installer. Verified against
**DoomRunner v1.9.2** (Qt/C++, [Youda008/DoomRunner](https://github.com/Youda008/DoomRunner))
and the current Steam client on SteamOS. Source references are `file:line`
from the `v1.9.2` tag.

---

## 1. DoomRunner data files

All under the **AppData** dir `~/.local/share/DoomRunner/` (>= 1.9;
*not* `~/.config` — the old location is only migrated when the new one
doesn't exist yet):

| File | Purpose |
| --- | --- |
| `options.json` | all settings: engines, IWADs dirs, presets, window state |
| `errors.txt` | append-only log of config load/save problems |
| `file_info_cache.json` | cached wad metadata — auto-regenerates, safe to delete |

**DoomRunner keeps `options.json` in memory and rewrites it on exit.**
Always close it before editing (the installer `pgrep`-guards for this).

## 2. `options.json` structure (only what we seed)

```jsonc
{
  "version": "1.9.2",              // DoomRunner stamps its own version back
  "engines": {
    "default_engine": "<engine id>",   // >= 1.9.2: engine.id (older: executable path)
    "engine_list": [ { "id", "name", "path", "config_dir", "data_dir", "family" } ]
  },
  "IWADs": {
    "directory": "/abs/path/iwads",
    "auto_update": true,        // list built from directory at runtime;
                                // an "IWAD_list" key is only serialized when
                                // auto_update is FALSE (OptionsSerializer.cpp:181)
    "search_subdirs": true,
    "default_iwad": ""
  },
  "maps":  { "directory": "/abs/path/mods/Maps" },
  "mods":  { "last_used_dir": "/abs/path/mods/Mods" },
  "global_options": {
    "use_preset_name_as_config_dir": true,   // per-preset config/save isolation
    "use_preset_name_as_save_dir": true
  },
  "use_absolute_paths": true,
  "presets": [ /* see below */ ],
  "selected_preset": "DOOM Fusion"           // stored by NAME
}
```

> **The `version` key is not optional** (learned 2026-10 on PopOS): a file
> *without* it is routed to the pre-1.7 compat loader
> (`OptionsSerializer.cpp:466-491`), which expects legacy keys
> (`engines/engines`, `IWADs/subdirs`, top-level `use_preset_name_as_*`...),
> silently ignores the whole modern schema — our `engine_list` never loads —
> and then the `version < 1.9.2` migration re-reads `selected_engine` as an
> *executable path*, producing "engine ... was removed from the list, please
> select another one" dialogs for every preset
> (`OptionsSerializer.cpp:386-402`). On exit DoomRunner rewrites the file with
> `engine_list: []`, i.e. it persists the deletion. **Always stamp `version`
> with the exact installed DoomRunner version** (the script passes the release
> tag) **and seed the complete key set** — every key below is `MustBePresent`
> and warns individually when absent.

> **Policy flags are seeded, not forced** (learned 2026-10 on review):
> `auto_update`, `search_subdirs` and the four `use_preset_name_as_*`
> booleans are applied **only when the key is absent** from an existing
> `options.json`; `default_engine` and `selected_preset` are only claimed
> when empty or pointing at an engine/preset that no longer exists.
> Re-running the installer must never revert a toggle the user made in the
> GUI. The *directory* fields (`IWADs.directory`, `maps.directory`,
> `mods.last_used_dir`) are the exception: they are installer-owned and
> repointed to the current root on every run (the root itself must be
> absolute — the script `cd`s into it before writing anything).

> **Seed correct JSON types per key** (learned 2026-10): `MustBePresent`
> keys are also type-checked — `"video_options.resolution_x/y"` are `uint`,
> so a seeded `null` produces *"has invalid type. Expected uint. Using
> default value"* on every load. The GUI writes `0` (= auto) there; a
> re-run coerces non-int values back to `0`. Only genuinely optional
> fields (`app_style`, `player_color`) may be `null`.

Complete key set the 1.9.2 GUI reads/writes (see the `DEFAULTS` skeleton in
`seed_doomrunner_config`): the sections above plus top-level
`launch_options`, `multiplayer_options`, `gameplay_options`,
`compatibility_options`, `video_options`, `audio_options` (all read because
`options_storage` defaults to `StoreGlobally=1`), `options_storage`
(`launch_opts/gameplay_opts/compat_opts/video_opts/audio_opts`),
`global_options` (4 × `use_preset_name_as_*` + `additional_args`,
`cmd_prefix`, `env_vars`), `use_absolute_paths`,
`geometry{x,y,width,height}`, `color_scheme`, `preset_search
{panel_expanded,case_sensitive,use_regex}`, `app_style` (null = system),
and `AllowMissing` ones: `show_engine_output`, `close_on_launch`,
`close_output_on_success`, `check_for_updates`,
`ask_for_sandbox_permissions`, `wrap_lines_in_txt_viewer`, `hide_map_label`.
Engine object keys: `id` (optional), `name`, `path`, `config_dir`, `data_dir`,
`family` ∈ {`ZDoom`, `ChocolateDoom`, `PrBoom`, `MBF`, `EDGE`, `KEX`}
(`UserData.cpp:142-177`, `EngineTraits.cpp:42-50`).

## 3. Preset schema

Write presets **exactly** in the shape the GUI writes. A partial preset makes
DoomRunner pop an "Error loading JSON file" dialog on first load and log one
line per missing key to `errors.txt` (`JsonObjectCtx::missingKey`,
`Utils/JsonUtils.cpp:520`):
`Element /presets/[N]/compatibility_options is missing in options.json. Using default value.`

Full preset (all keys required in practice — see storage-mode caveat below):

```jsonc
{
  "name": "...",
  "selected_engine": "uzdoom-flatpak",
  "selected_config": "",              // empty = engine default config
  "selected_IWAD": "/abs/path/to.iwad", // empty IS allowed (see §5)
  "selected_mappacks": [ "/abs/path", ... ],
  "mods": [ { "checked": true, "path": "/abs/path.pk3" } ],  // loaded in list order
  "load_maps_after_mods": false,
  "compatibility_options": { "compat_mode": -1, "compatflags1": 0, "compatflags2": 0 },
  "alternative_paths": { "config_dir": "", "save_dir": "", "demo_dir": "", "screenshot_dir": "" },
  "additional_args": "",
  "env_vars": {}
}
```

* `mods` entries are `{checked, path}` objects; the engine loads them in list
  order (drag to reorder in the GUI). Alphabetical order can be wrong for
  base-mod → patch stacks (e.g. BD patch sorts before `brutalv21.pk3`).
* `launch_options` / `multiplayer_options` / `gameplay_options` /
  `compatibility_options` / `video_options` / `audio_options` inside a preset
  are only read/written when `options_storage` says "store to preset"
  (`OptionsSerializer.cpp:126-143`). `alternative_paths` is **always** read and
  warns when absent. Seeding the full shape covers both modes.
* The GUI-created presets never contain the per-preset option groups unless
  per-preset storage is enabled — don't add them by default.
* `selected_engine` stores the engine **id** (>= 1.9.2). DoomRunner clears it
  on load when the id is unknown (and old broken seeds emptied it) — the
  repair pass re-points presets whose selection is empty/unknown to our
  managed engine, and never touches a valid other-engine choice.

## 4. Paths: ALWAYS absolute (the `/tmp/.mount_*` trap)

This one bit us: seeding `"selected_IWAD": "DOOM.WAD"` (bare filename) ended up
persisted as `"/tmp/.mount_DoomRuOGmmCn/usr/bin/DOOM.WAD"` — a path that no
longer exists after the AppImage unmounts. Chain of causality:

1. `main.cpp:27` — DoomRunner calls `QDir::setCurrent(applicationDirPath())`;
   for the AppImage that CWD is the **ephemeral** `/tmp/.mount_DoomRuXXXX/usr/bin`
   (mount name is random per session).
2. The `PathConvertor` is built with that CWD as base dir
   (`MainWindow.cpp:839`): "all relative paths are stored internally relative
   to the current working dir" (`Utils/FileSystemUtils.hpp:265-330`).
3. With `use_absolute_paths: true`, relative paths are absolutized against CWD
   and persisted (`MainWindow::togglePathStyle`, `MainWindow.cpp:4863`).

So: **never write relative paths into `options.json`**. Default on Linux is
already `PathStyle::Absolute` (`UserData.hpp:50-53`); the installer forces
`use_absolute_paths: true` so future relative writes get pinned to the real
root instead of a tmp mount. (The AppImage ships no WADs — verified with 7z —
so nothing real ever lived in that mount.)

## 5. IWAD validation when a preset is clicked

`MainWindow::restoreSelectedIWAD` (`MainWindow.cpp:2040-2062`):

* `selected_IWAD` is matched against the live IWAD model (scan of `IWADs.directory`).
* Not found or file missing → popup *"IWAD selected for this preset (…) no
  longer exists"* and the field is cleared.
* **An empty `selected_IWAD` is fine** — no popup. This is why the mod-folder
  presets we generate leave it empty: the user picks the game once, per preset.

## 6. Steam non-Steam game shortcuts

* File: `<steam>/userdata/<steamid32>/config/shortcuts.vdf`, **one per user
  profile**. `~/.steam/steam` is normally a symlink to `~/.local/share/Steam`.
* **Steam keeps it in memory and rewrites on exit** — only edit while Steam is
  closed. On the Deck, switching Desktop↔Gaming restarts Steam, which reloads
  the file, so "quit desktop Steam → write → switch to Gaming mode" works.

### Binary VDF format

Observed in real `shortcuts.vdf` files: `0x00` open section … `0x08` end
section, `0x01` null-terminated string key+value, `0x02` int32 LE.
**The entire file is a root section, closed by one final `0x08`** — forgetting
it produced an unparseable file during testing (that last byte matters!).
Valve's wider type set also includes `0x03` float, `0x05` wide string,
`0x08` uint64, `0x0A` int64. Our parser round-trips `0x03`/`0x04` with their
original type byte (typed int wrappers) and normalizes `0x0A` to `0x0B`
(both signed 64-bit); still error out loudly on unknown types (`0x05` etc.)
instead of silently rewriting a file you don't fully understand.

### Shortcut entry fields (current Steam, note lowercase `appname`/`exe`)

```
appid (int32, signed — non-Steam ids have the high bit set, so they LOOK
      negative), appname, exe ("\"/path\""), StartDir ("/path/" trailing slash,
      unquoted), icon, ShortcutPath, LaunchOptions, IsHidden,
      AllowDesktopConfig, AllowOverlay, OpenVR, Devkit, DevkitGameID,
      DevkitOverrideAppID, LastPlayTime, FlatpakAppID, sortas, tags { "0": "favorite" }
```

`exe` is stored **double-quoted**; `LaunchOptions` gets appended as-is
(`%command%` semantics apply).

### The appid rules

* Non-Steam appids are 32-bit with the high bit set (stored as negative int32).
* The usual formula `crc32(exe + appname) | 0x80000000` **does NOT reproduce
  what Steam stores** (tested against several real entries; Steam's input form
  to the hash is unknown/varies). It doesn't matter:
* Steam does **not recompute the appid** after the shortcut is added —
  renaming a shortcut keeps the appid, and third-party tools (EmuDeck) ship
  entries with arbitrary ids that work fine. The only requirements: unique and
  high bit set. Our generator uses `crc32(exe + name) | 0x80000000` for
  determinism.
* On AppImage upgrades we rebind `exe`/`StartDir` but **keep the appid**, so
  custom art and Steam-side data survive.

### Recognizing our own entry

Pass 1 matches a shortcut by `appname == "DoomRunner"` **or** by the basename
of `exe` matching `DoomRunner-*.appimage` (case-insensitive). appname-only
matching breaks the moment the user renames the entry (the appid survives the
rename, so the renamed entry is still "ours"): the next path change (version
bump, moved root) would then miss it and add a duplicate next to the stale
original. All matched entries are repaired, never deleted, and their `appname`
is left untouched.

The appid is **per-profile data**: every profile keys its grid art (and the
`icon` field of freshly added entries) by **its own** matched entry's appid —
preferring a match whose grid files (`<id>.*`, `<id>_*.*`, `<id>p.*`) already
exist, so a renamed duplicate never orphans the art. A profile that gets a
new entry receives the first appid found anywhere else (or a deterministic
crc32 when none exists yet), which keeps one user's rename from mis-keying
another user's library. Profiles that lack the entry while Steam runs cannot
be written at all — they are counted as `skipped` and the step exits 3
instead of claiming success.

### Custom grid art

Flat files in `<steam>/userdata/<steamid32>/config/grid/`, prefix = the
**unsigned decimal** appid (e.g. `2573120213` for the shortcut stored as
`-1721847083`):

| File | Art | Observed size |
| --- | --- | --- |
| `<id>_hero.png` | hero banner | 1920x620 |
| `<id>_logo.png` | hero logo overlay | 1064x654 RGBA |
| `<id>.png`      | capsule (landscape) | 920x430 |
| `<id>p.png`     | capsule (portrait) | 600x900 |
| `<id>_icon.png` | icon (`.ico` for some entries) | 1024x1024 |
| `<id>.json`     | art layout | `{"nVersion":1,"logoPosition":{"pinnedPosition":"BottomLeft","nWidthPct":50,"nHeightPct":50}}` |

Copy targets are content-checked (skip when size matches) and keyed by each
profile's own appid. If we install an icon for a shortcut we create, its
`icon` field points at that profile's own grid `_icon.png`; existing entries
are never touched.

## 7. Editing workflow rules (what the installer follows)

1. Refuse to touch `options.json` while DoomRunner runs; refuse `shortcuts.vdf`
   while Steam runs (both rewrite on exit).
2. Timestamped `.bak` next to every rewritten file.
3. Seed by **merge**, never replace; repair missing keys in place; never
   overwrite user-curated presets (match by `name`) and never revert policy
   booleans the user toggled (seed them only when the key is absent).
4. Everything absolute; everything idempotent — re-running repairs, never
   duplicates.
5. Write via temp file + atomic rename in the same directory.

## 8. Where to re-verify

| Fact | Source (`v1.9.2`) |
| --- | --- |
| missing-key warnings + message text | `Sources/Utils/JsonUtils.cpp:520` |
| missing `version` routes to pre-1.7 compat loader | `Sources/OptionsSerializer.cpp:466-491` |
| preset engine-id "removed from list" migration | `Sources/OptionsSerializer.cpp:386-402` |
| engine JSON keys + family strings | `Sources/UserData.cpp:142-177`, `Sources/EngineTraits.cpp:42-50` |
| storage-mode-gated option groups | `Sources/OptionsSerializer.cpp:201-217` |
| preset serialize/deserialize | `Sources/OptionsSerializer.cpp:37-159` |
| `IWAD_list` only when auto_update off | `Sources/OptionsSerializer.cpp:181` |
| CWD = executable dir | `Sources/main.cpp:27` |
| PathConvertor base = CWD | `Sources/MainWindow.cpp:839`, `Utils/FileSystemUtils.hpp:265` |
| absolute-path toggle rewrites everything | `Sources/MainWindow.cpp:4863` |
| "IWAD no longer exists" on preset select | `Sources/MainWindow.cpp:2040` |
| `defaultPathStyle` per-OS | `Sources/UserData.hpp:50-53` |
| `use_absolute_paths` key | `Sources/UserData.cpp:680` |
