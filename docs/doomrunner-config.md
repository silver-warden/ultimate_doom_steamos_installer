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
`0x08` uint64, `0x0A` int64 — error out loudly on unknown types instead of
silently rewriting a file you don't fully understand.

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

Copy targets are content-checked (skip when size matches). If we install an
icon for a shortcut we create, its `icon` field points at the grid `_icon.png`;
existing entries are never touched.

## 7. Editing workflow rules (what the installer follows)

1. Refuse to touch `options.json` while DoomRunner runs; refuse `shortcuts.vdf`
   while Steam runs (both rewrite on exit).
2. Timestamped `.bak` next to every rewritten file.
3. Seed by **merge**, never replace; repair missing keys in place; never
   overwrite user-curated presets (match by `name`).
4. Everything absolute; everything idempotent — re-running repairs, never
   duplicates.
5. Write via temp file + atomic rename in the same directory.

## 8. Where to re-verify

| Fact | Source (`v1.9.2`) |
| --- | --- |
| missing-key warnings + message text | `Sources/Utils/JsonUtils.cpp:520` |
| preset serialize/deserialize | `Sources/OptionsSerializer.cpp:37-159` |
| `IWAD_list` only when auto_update off | `Sources/OptionsSerializer.cpp:181` |
| CWD = executable dir | `Sources/main.cpp:27` |
| PathConvertor base = CWD | `Sources/MainWindow.cpp:839`, `Utils/FileSystemUtils.hpp:265` |
| absolute-path toggle rewrites everything | `Sources/MainWindow.cpp:4863` |
| "IWAD no longer exists" on preset select | `Sources/MainWindow.cpp:2040` |
| `defaultPathStyle` per-OS | `Sources/UserData.hpp:50-53` |
| `use_absolute_paths` key | `Sources/UserData.cpp:680` |
