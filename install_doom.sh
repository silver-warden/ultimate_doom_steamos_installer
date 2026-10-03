#!/usr/bin/env bash
#===============================================================================
# Ultimate Doom installer for SteamOS and Linux (Steam Deck and friends)
#===============================================================================
# Automates the full classic-Doom setup on a Steam Deck running in Desktop mode:
#
#   1. Preflight  - SteamOS/desktop checks, flathub remote, curl/python3 present
#   2. UZDoom     - install the org.zdoom.UZDoom flatpak from Flathub
#                   (system-wide first, fall back to --user)
#   3. DoomRunner - find latest release via the GitHub API, reuse a matching
#                   AppImage already in the Doom root, otherwise download it
#   4. Wrapper    - ~/.local/bin/uzdoom -> `flatpak run org.zdoom.UZDoom "$@"`
#                   so the (host) DoomRunner AppImage can launch the flatpak
#                   engine; DoomRunner also auto-detects the engine by name.
#                   Sets gamescope's GAMESCOPE_COMPOSITE_FORCE root property
#                   (gamescope#1368 direct-scanout artifact workaround)
#   5. Doom root  - prompt for the Doom root folder (default
#                   ~/Games/Doom), create the layout:
#                     <root>/iwads   <root>/tools   <root>/mods/{Mods,Maps,
#                     Graphics,Sound}
#   6. Sandbox    - one recursive flatpak override gives UZDoom access to the
#                   whole tree (all current + future subfolders) plus
#                   DOWADPATH pointing at the IWADs dir. Flatseal is installed
#                   for optional manual review (same settings, GUI).
#   7. IWADs      - md5-scan <root>/iwads and the Steam libraries against
#                   WadFusion's RECOMMENDED-hash table, stage matches under the
#                   preferred filenames; fall back to name matching (with a
#                   warning) for slots with no hash match; stage KEX re-release
#                   wads as *kex.wad so WadFusion extracts widescreen assets
 #   8. Extras     - stage owned Heretic / Hexen / Strife / Chex Quest wads
 #                   found in the Steam libraries under UZDoom's canonical
 #                   filenames, and (opt-in prompts) download the free IWADs:
 #                   Freedoom Phase 1 + 2 and Blasphemer (Heretic TC)
 #   9. WadFusion  - download wadfusion_py.zip, run it (pure-Python, no deps),
 #                   copy the generated doom_fusion.ipk3 (+ widescreen pk3)
 #                   into <root>/iwads
 #  10. Config     - seed/merge ~/.local/share/DoomRunner/options.json (the
#                   AppData dir DoomRunner >= 1.9 actually uses; backed up):
#                   UZDoom engine entry (family ZDoom, config/data dirs into
#                   the flatpak's ~/.var/app tree), IWADs dir with
 #                   auto_update, maps dir + mods last-used dir, a "DOOM Fusion"
 #                   preset using UZDoom + doom_fusion.ipk3, plus one preset per
 #                   other game IWAD present (Heretic, Hexen, Strife, Chex,
 #                   Freedoom, Blasphemer) + per-preset config/save isolation,
 #                   and one preset per mods/Mods subfolder bundling its
 #                   pk3/wad/deh files (IWAD left to pick in the GUI)
 #  11. Shortcut   - add DoomRunner to Steam's library as a non-Steam game
#                   (binary shortcuts.vdf in every user profile) and install
#                   the grid art from steam_art/ next to this script (fetched
#                   from the repo when that folder is absent); skipped with a
#                   hint while Steam runs, which would rewrite the vdf
 #  12. Verify     - `uzdoom -version`, sandbox visibility of the mod tree,
 #                   ipk3 integrity, then a summary with manual next steps
 #
 # Usage:
 #   ./install_doom.sh [-y] [--root DIR] [--force] [--extras] [--no-extras]
 #     -y, --yes        non-interactive, accept everything (incl. extras)
 #     --root DIR       Doom root folder (skips the prompt)
 #     --force          re-download DoomRunner/WadFusion/Freedoom/Blasphemer
 #                      and rebuild the ipk3 even if already in place
 #     --extras         auto-accept the optional Freedoom/Blasphemer downloads
 #     --no-extras      auto-decline them (also overrides -y)
#
# Idempotent: safe to re-run; every step detects existing installs.
#===============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# Defaults / constants
#------------------------------------------------------------------------------
UZDOOM_APP_ID="org.zdoom.UZDoom"
FLATSEAL_APP_ID="com.github.tchx84.Flatseal"
UZDOOM_VAR_DIR="$HOME/.var/app/$UZDOOM_APP_ID/config/ZDoom"
UZDOOM_WRAPPER="$HOME/.local/bin/uzdoom"
DOOMRUNNER_REPO="Youda008/DoomRunner"
WADFUSION_ZIP_URL="https://github.com/Owlet7/wadfusion/releases/latest/download/wadfusion_py.zip"
FREEDOOM_REPO="freedoom/freedoom"
FREEDOOM_FALLBACK_URL="https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
BLASPHEMER_REPO="Blasphemer/blasphemer"
BLASPHEMER_FALLBACK_URL="https://github.com/Blasphemer/blasphemer/releases/download/v0.1.8/blasphem-0.1.8.zip"
DEFAULT_ROOT="$HOME/Games/Doom"    # /home/deck/Games/Doom on the Deck
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STEAM_ART_DIR="$SCRIPT_DIR/steam_art"   # optional non-Steam-game grid art
STEAM_ART_BASE="https://raw.githubusercontent.com/silver-warden/ultimate_doom_steamos_installer/main/steam_art"
STEAM_DIRS=(
	"$HOME/.local/share/Steam/steamapps/common"
	"$HOME/.steam/steam/steamapps/common"
	/run/media/*/Steam/steamapps/common
	/run/media/*/steamapps/common
	/run/media/*/*/steamapps/common
	/media/*/*/Steam/steamapps/common
	/media/*/*/steamapps/common
	/media/*/*/*/steamapps/common
)
RUNNER_BIN=""          # filled by install_doomrunner
DR_TAG="v1.9.2"        # DoomRunner version tag, set by install_doomrunner
ROOT=""                # filled by ask_root

AUTO_YES=0
FORCE=0
EXTRAS=-1         # -1 prompt, 0 decline, 1 accept (--extras / --no-extras)

#------------------------------------------------------------------------------
# Logging helpers
#------------------------------------------------------------------------------
C_STEP=$'\e[1;34m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$*" "$C_OFF"; }
ok()   { printf '%s  [ok]%s %s\n'  "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s [!!!]%s %s\n'  "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s [XX]%s  %s\n'  "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }

ask() { # ask <prompt> <default> ; echoes the answer
	local prompt="$1" def="$2" ans
	if (( AUTO_YES )); then printf '%s\n' "$def"; return; fi
	read -r -e -p "$prompt" -i "$def" ans || ans="$def"
	printf '%s\n' "${ans:-$def}"
}

confirm() { # confirm <question> ; true on yes (-y accepts everything unless --no-extras)
	local ans
	case "$EXTRAS" in
		1) return 0 ;;
		0) return 1 ;;
	esac
	if (( AUTO_YES )); then return 0; fi
	read -r -e -p "$1 [y/N] " ans || ans=""
	[[ "${ans,,}" =~ ^(y|yes)$ ]]
}

latest_asset() { # latest_asset <repo> <asset-regex> ; echoes "<tag> <url>"
	curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if re.search(sys.argv[1], a["name"]):
        print(d["tag_name"], a["browser_download_url"]); break
' "$2" 2>/dev/null || true
}

#------------------------------------------------------------------------------
# Arg parsing
#------------------------------------------------------------------------------
ROOT_OVERRIDE=""
while (( $# )); do
	case "$1" in
		-y|--yes)  AUTO_YES=1 ;;
		--force)   FORCE=1 ;;
		--extras)    EXTRAS=1 ;;
		--no-extras) EXTRAS=0 ;;
		--root)    ROOT_OVERRIDE="${2:?--root needs a directory}"; shift ;;
		# header = line 3 .. the second "#===" rule (first two are the opening
		# fence around the title, the next one closes the block)
		-h|--help) awk 'NR == 1 { next } /^#=/ { if (++barr > 2) exit; next } NR >= 3 { print }' "$0"; exit 0 ;;
		*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

#------------------------------------------------------------------------------
# 1. Preflight
#------------------------------------------------------------------------------
preflight() {
	step "Preflight checks"

	[[ -r /etc/os-release ]] && grep -q SteamOS /etc/os-release \
		|| warn "not SteamOS - continuing anyway"
	[[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] \
		|| warn "no display server detected - run this in Desktop mode for GUI steps"

	command -v flatpak >/dev/null || die "flatpak not found"
	command -v curl    >/dev/null || die "curl not found"
	command -v python3 >/dev/null || die "python3 not found (needed by WadFusion and config seeding)"

	if ! flatpak remotes 2>/dev/null | grep -qiw flathub; then
		warn "flathub remote missing - adding it"
		flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null \
			|| flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
	fi
	ok "environment looks good"
}

#------------------------------------------------------------------------------
# 2. UZDoom flatpak (+ Flatseal for optional manual review)
#------------------------------------------------------------------------------
install_uzdoom() {
	step "Installing UZDoom ($UZDOOM_APP_ID)"
	if flatpak info "$UZDOOM_APP_ID" >/dev/null 2>&1; then
		ok "already installed - updating"
		flatpak update -y --noninteractive "$UZDOOM_APP_ID" || true
	elif flatpak install -y --noninteractive flathub "$UZDOOM_APP_ID" 2>/dev/null; then
		ok "installed system-wide"
	elif flatpak install -y --noninteractive --user flathub "$UZDOOM_APP_ID"; then
		ok "installed for current user"
	else
		die "could not install $UZDOOM_APP_ID"
	fi

	if flatpak info "$FLATSEAL_APP_ID" >/dev/null 2>&1; then
		ok "Flatseal already installed (GUI for reviewing permissions)"
	else
		flatpak install -y --noninteractive flathub "$FLATSEAL_APP_ID" 2>/dev/null \
			|| flatpak install -y --noninteractive --user flathub "$FLATSEAL_APP_ID" 2>/dev/null \
			|| warn "Flatseal install failed - not fatal, overrides below are applied via CLI"
	fi
}

#------------------------------------------------------------------------------
# 3. DoomRunner AppImage (latest from GitHub, reuse if already present)
#------------------------------------------------------------------------------
install_doomrunner() {
	step "Setting up DoomRunner"
	local api latest asset name existing ebase
	api=$(curl -fsSL "https://api.github.com/repos/$DOOMRUNNER_REPO/releases/latest" 2>/dev/null || true)
	latest=$(printf '%s' "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || true)
	asset=$(printf '%s' "$api" | python3 -c '
import json,sys
for a in json.load(sys.stdin)["assets"]:
    n = a["name"]
    if "Linux-x86_64.AppImage" in n:
        print(a["browser_download_url"]); break
' 2>/dev/null || true)

	if [[ -z "$latest" || -z "$asset" ]]; then
		warn "GitHub API unreachable - falling back to v1.9.2"
		latest="v1.9.2"
		asset="https://github.com/$DOOMRUNNER_REPO/releases/download/v1.9.2/DoomRunner-1.9.2-Linux-x86_64.AppImage"
	fi

	DR_TAG="$latest"

	# reuse an existing AppImage in the Doom root if its version matches
	shopt -s nullglob nocaseglob
	# exact filename (lowercased - nocaseglob let any casing through): a plain
	# substring match of the tag would reuse e.g. 1.9.20 for 1.9.2, or match a
	# digit-bearing root path
	for existing in "$ROOT"/DoomRunner-*-Linux-x86_64.AppImage; do
		ebase="${existing##*/}"; ebase="${ebase,,}"
		if [[ "$ebase" == "doomrunner-${latest#v}-linux-x86_64.appimage" ]]; then
			RUNNER_BIN="$existing"
			ok "reusing ${existing##*/}"
			shopt -u nullglob nocaseglob
			return
		fi
	done
	shopt -u nullglob nocaseglob

	name="${asset##*/}"
	RUNNER_BIN="$ROOT/$name"
	if (( ! FORCE )) && [[ -f "$RUNNER_BIN" ]]; then
		ok "$name already downloaded"
	else
		printf '%s  downloading%s %s\n' "$C_DIM" "$C_OFF" "$name"
		curl -fL --retry 3 -o "$RUNNER_BIN.part" "$asset"
		mv -f "$RUNNER_BIN.part" "$RUNNER_BIN"
		ok "installed $name"
	fi
	chmod +x "$RUNNER_BIN"
}

#------------------------------------------------------------------------------
# 4. Engine wrapper so the AppImage can launch the flatpak engine
#------------------------------------------------------------------------------
make_wrapper() {
	step "Creating engine wrapper"
	mkdir -p "$HOME/.local/bin" "$UZDOOM_VAR_DIR"
	cat > "$UZDOOM_WRAPPER" <<'EOF'
#!/bin/sh
# Launches the UZDoom flatpak like a native binary (used by DoomRunner).
# gamescope#1368 / drm-amd#3441: on Steam Deck's DCN display engine the
# primary plane gets corrupted during direct scanout when the cursor plane
# churns (mouse/rstick look). Ask gamescope to always composite this session.
if [ -n "${DISPLAY:-}" ] && command -v xprop >/dev/null 2>&1; then
	xprop -root -f GAMESCOPE_COMPOSITE_FORCE 32c -set GAMESCOPE_COMPOSITE_FORCE 1 2>/dev/null || true
fi
exec flatpak run org.zdoom.UZDoom "$@"
EOF
	chmod +x "$UZDOOM_WRAPPER"
	case ":$PATH:" in
		*":$HOME/.local/bin:"*) ;;
		*) warn "~/.local/bin is not in PATH - add it (needed by DoomRunner auto-detect only; options.json uses the absolute path)" ;;
	esac
	ok "$UZDOOM_WRAPPER -> flatpak run $UZDOOM_APP_ID"
}

#------------------------------------------------------------------------------
# 5. Doom root folder + layout
#------------------------------------------------------------------------------
ask_root() {
	step "Doom folder"
	if [[ -n "$ROOT_OVERRIDE" ]]; then
		ROOT="$ROOT_OVERRIDE"
	else
		ROOT=$(ask "Doom root folder [$DEFAULT_ROOT]: " "$DEFAULT_ROOT")
	fi
	ROOT="${ROOT/#\~/$HOME}"
	mkdir -p "$ROOT"/{iwads,tools,mods/Mods,mods/Maps,mods/Graphics,mods/Sound,mods/Music,mods/Performance}
	# absolutize - everything we write into options.json / shortcuts.vdf /
	# flatpak overrides must be absolute (see docs/doomrunner-config.md - the
	# /tmp/.mount_* trap - and flatpak rejects relative filesystem paths)
	ROOT=$(cd -- "$ROOT" && pwd)
	ok "root: $ROOT"
	if [[ -f "$ROOT/mods/Put your mods (.pk3 etc) files here.txt" || -n "$(ls -A "$ROOT/mods/Mods" 2>/dev/null)" ]]; then
		ok "found existing mod library"
	fi
}

#------------------------------------------------------------------------------
# 6. Flatpak permissions (recursive filesystem access for UZDoom)
#------------------------------------------------------------------------------
grant_permissions() {
	step "Granting UZDoom access to the Doom folder"
	# A single filesystem permission on a directory is recursive: the whole
	# tree under $ROOT (all subfolders, incl. ones created later) is visible.
	# --user overrides apply whether UZDoom was installed system-wide or not.
	flatpak override --user "$UZDOOM_APP_ID" \
		--filesystem="$ROOT" \
		--env=DOWADPATH="$ROOT/iwads" \
		--env=DOOMWADPATH="$ROOT/iwads"
	ok "recursive access to $ROOT + DOWADPATH/DOOMWADPATH=$ROOT/iwads"
	flatpak override --show "$UZDOOM_APP_ID" | sed 's/^/       /'
}

#------------------------------------------------------------------------------
# 7. IWAD collection: md5-match Steam + <root>/iwads against WadFusion's
#    recommended-hash table, stage under preferred filenames
#------------------------------------------------------------------------------
collect_iwads() {
	step "Collecting official WADs (hash-verified)"
	local staging="$WF_DIR/source_wads"
	mkdir -p "$staging"

	# md5 -> staged filename (WadFusion "Recommended WADs" table; Ultimate
	# Doom is intentionally staged as DOOMU.WAD per the README)
	local -A WANT=(
		[c4fe9fd920207691a9f493668e0a2083]="DOOMU.WAD"
		[1cd63c5ddff1bf8ce844237f580e9cf3]="DOOM.WAD"
		[25e1459ca71d321525f84628f45ca8cd]="DOOM2.WAD"
		[4e158d9953c79ccf97bd0663244cc6b6]="TNT.WAD"
		[75c8cf89566741fa9d22447604053bd7]="PLUTONIA.WAD"
		[ab3ce78e085e50a61f6dff46aabbfaeb]="masterlevels.wad"
		[23422eb42833ac7b0dd59c0c7ae18a6f]="nerve.wad"
		[08ee05388c137db5f5d7996e89425b95]="sigil.wad"
		[953f65cf079d0ba9a25be2c407da7ec1]="sigil2.wad"
		[713c5a3c1734b1d55b2813a3dd0136d9]="id1.wad"
		[cb92010b8ec05f8924ac966a8ed95b74]="iddm1.wad"
		[2e76d93d52ef64fb9db3cee2437c686b]="extras.wad"
	)

	local -A HAVE=()   # staged filename -> source
	local -A NAME_FALLBACK=(
		[doom.wad]="DOOMU.WAD" [doomu.wad]="DOOMU.WAD"
		[doom2.wad]="DOOM2.WAD" [tnt.wad]="TNT.WAD" [plutonia.wad]="PLUTONIA.WAD"
		[masterlevels.wad]="masterlevels.wad" [nerve.wad]="nerve.wad"
		[sigil.wad]="sigil.wad" [sigil2.wad]="sigil2.wad"
		[id1.wad]="id1.wad" [iddm1.wad]="iddm1.wad" [extras.wad]="extras.wad"
	)

	# scan roots: our iwads dir first (preferred), then Steam libraries
	local scan_roots=("$ROOT/iwads") d
	for d in "${STEAM_DIRS[@]}"; do
		[[ -d "$d" ]] && scan_roots+=("$d")
	done

	# collect first, then two passes: a hash match must never lose to a
	# later name-only fallback (find order depends on the filesystem, so
	# e.g. rerelease/doom2.wad used to beat base/doom2.wad)
	local wads=() wad sum target lower pass
	while IFS= read -r -d '' wad; do wads+=("$wad"); done \
		< <(find "${scan_roots[@]}" -maxdepth 4 -type f -iname '*.wad' -print0 2>/dev/null)

	for pass in hash name; do
		for wad in "${wads[@]}"; do
			if [[ "$pass" == hash ]]; then
				sum=$(md5sum "$wad" | cut -d' ' -f1)
				target="${WANT[$sum]:-}"
			else
				lower="${wad,,}"; lower="${lower##*/}"
				target="${NAME_FALLBACK[$lower]:-}"
				[[ -z "$target" || -n "${HAVE[$target]:-}" ]] && continue
				warn "hash does not match WadFusion's recommended version: $wad"
				warn "  staging it as $target anyway"
			fi
			[[ -n "$target" && -z "${HAVE[$target]:-}" ]] || continue
			cp -f "$wad" "$staging/$target"
			HAVE[$target]="$wad"
			ok "$target  ${C_DIM}<- $wad${C_OFF}"
		done
	done

	# KEX re-release wads renamed so WadFusion extracts official widescreen gfx
	local kex_dirs=("$HOME/.local/share/Steam/steamapps/common/Ultimate Doom/rerelease"
	                "$HOME/.steam/steam/steamapps/common/Ultimate Doom/rerelease")
	local kex f src dst
	for kex in "${kex_dirs[@]}"; do
		[[ -d "$kex" ]] || continue
		for f in doom:doomkex.wad doom2:doom2kex.wad tnt:tntkex.wad plutonia:plutoniakex.wad; do
			src="${f%%:*}"; dst="${f##*:}"
			if [[ -f "$kex/$src.wad" && ! -e "$staging/$dst" ]]; then
				cp "$kex/$src.wad" "$staging/$dst"
				ok "$dst ${C_DIM}(widescreen gfx source)${C_OFF}"
			fi
		done
		break
	done

	local missing=() t
	for t in DOOMU.WAD DOOM2.WAD TNT.WAD PLUTONIA.WAD masterlevels.wad nerve.wad sigil.wad sigil2.wad id1.wad iddm1.wad extras.wad; do
		[[ -e "$staging/$t" ]] || missing+=("$t")
	done
	if (( ${#missing[@]} )); then
		warn "not found (optional, Fusion will skip them): ${missing[*]}"
	fi
}

#------------------------------------------------------------------------------
# 8. Extras: stage owned Heretic/Hexen/Strife/Chex Quest wads (UZDoom
#    identifies these by filename, no WadFusion involvement) + optional
#    download of the free IWADs (Freedoom Phase 1+2, Blasphemer)
#------------------------------------------------------------------------------
stage_existing_wads() {
	step "Other owned games (Heretic / Hexen / Strife / Chex Quest)"
	# lowercased found name -> canonical name UZDoom's iwadinfo expects
	local -A CANON=(
		[heretic.wad]="heretic.wad" [evilution.wad]="evilution.wad"
		[hexen.wad]="hexen.wad"     [hexendk.wad]="hexendk.wad"
		[strife1.wad]="strife1.wad" [sve.wad]="sve.wad"
		[chex.wad]="chex.wad"       [chex3.wad]="chex3.wad"
	)
	local scan_roots=("$ROOT/iwads") d
	for d in "${STEAM_DIRS[@]}"; do
		[[ -d "$d" ]] && scan_roots+=("$d")
	done

	local -A SEEN=()
	local wad base target
	while IFS= read -r -d '' wad; do
		base="${wad,,}"; base="${base##*/}"
		target="${CANON[$base]:-}"
		[[ -z "$target" || -n "${SEEN[$target]:-}" ]] && continue
		SEEN[$target]=1
		if [[ "${wad%/*}" == "$ROOT/iwads" ]]; then
			ok "${target^^}  ${C_DIM}(already in iwads)${C_OFF}"
		else
			cp -f "$wad" "$ROOT/iwads/$target"
			ok "$target  ${C_DIM}<- $wad${C_OFF}"
		fi
	done < <(find "${scan_roots[@]}" -maxdepth 4 -type f -iname '*.wad' -print0 2>/dev/null)

	if (( ! ${#SEEN[@]} )); then
		ok "no Heretic/Hexen/Strife/Chex install found"
	fi
}

install_freedoom() {
	local f1="$ROOT/iwads/freedoom1.wad" f2="$ROOT/iwads/freedoom2.wad"
	if [[ -f "$f1" && -f "$f2" ]] && (( ! FORCE )); then
		ok "Freedoom already installed (use --force to update)"
		return
	fi
	if ! confirm "Download Freedoom Phase 1 + Phase 2 (free, ~60 MB) into $ROOT/iwads?"; then
		ok "Freedoom skipped"
		return
	fi
	local tag url tmp
	read -r tag url < <(latest_asset "$FREEDOOM_REPO" '^freedoom-[0-9].*\.zip$') || true
	if [[ -z "${url:-}" ]]; then
		warn "Freedoom GitHub API unreachable - falling back to v0.13.0"
		url="$FREEDOOM_FALLBACK_URL"
	fi
	tmp=$(mktemp -d)
	printf '%s  downloading%s %s\n' "$C_DIM" "$C_OFF" "${url##*/}"
	curl -fL --retry 3 -o "$tmp/freedoom.zip" "$url"
	unzip -oq "$tmp/freedoom.zip" -d "$tmp"
	find "$tmp" \( -name 'freedoom1.wad' -o -name 'freedoom2.wad' \) -exec mv -f {} "$ROOT/iwads/" \;
	rm -rf "$tmp"
	[[ -f "$f1" && -f "$f2" ]] || die "Freedoom archive did not contain freedoom1.wad/freedoom2.wad"
	ok "Freedoom ${tag:-} -> iwads/freedoom1.wad + iwads/freedoom2.wad"
}

install_blasphemer() {
	local dst="$ROOT/iwads/blasphemer.wad"
	if [[ -f "$dst" ]] && (( ! FORCE )); then
		ok "Blasphemer already installed (use --force to update)"
		return
	fi
	if ! confirm "Download Blasphemer (free Heretic total conversion, ~20 MB)?"; then
		ok "Blasphemer skipped"
		return
	fi
	local tag url tmp inner
	read -r tag url < <(latest_asset "$BLASPHEMER_REPO" '^blasphem-[0-9].*\.zip$') || true
	if [[ -z "${url:-}" ]]; then
		warn "Blasphemer GitHub API unreachable - falling back to v0.1.8"
		url="$BLASPHEMER_FALLBACK_URL"
	fi
	tmp=$(mktemp -d)
	printf '%s  downloading%s %s\n' "$C_DIM" "$C_OFF" "${url##*/}"
	curl -fL --retry 3 -o "$tmp/blasphemer.zip" "$url"
	# the release ships the classic 8.3 name blasphem.wad -> install under
	# UZDoom's canonical IWADName so DoomRunner labels it correctly
	inner=$(unzip -Z1 "$tmp/blasphemer.zip" | grep -i 'blasphem.*\.wad' | head -n1)
	[[ -n "$inner" ]] || die "Blasphemer archive layout unexpected (no blasphem*.wad)"
	unzip -p "$tmp/blasphemer.zip" "$inner" > "$dst.part"
	mv -f "$dst.part" "$dst"
	rm -rf "$tmp"
	ok "Blasphemer ${tag:-} -> iwads/blasphemer.wad"
}

install_extras() {
	stage_existing_wads
	install_freedoom
	install_blasphemer
}

#------------------------------------------------------------------------------
# 9. WadFusion download + run
#------------------------------------------------------------------------------
WF_DIR=""
setup_wadfusion() {
	step "WadFusion"
	WF_DIR="$ROOT/tools/wadfusion"

	if [[ ! -f "$WF_DIR/wadfusion.py" || $FORCE -eq 1 ]]; then
		local tmp
		tmp=$(mktemp -d)
		curl -fL --retry 3 -o "$tmp/wadfusion.zip" "$WADFUSION_ZIP_URL"
		unzip -oq "$tmp/wadfusion.zip" -d "$WF_DIR"
		rm -rf "$tmp"
		ok "installed to $WF_DIR"
	else
		ok "already installed at $WF_DIR"
	fi

	if [[ -f "$ROOT/iwads/doom_fusion.ipk3" && $FORCE -eq 0 ]]; then
		ok "doom_fusion.ipk3 already built (use --force to rebuild)"
		return
	fi

	collect_iwads

	printf '%s  running wadfusion.py...%s\n' "$C_DIM" "$C_OFF"
	# printf instead of `yes`: under pipefail, `yes` would die of SIGPIPE (141)
	# and poison the exit code even when the build succeeds
	(cd "$WF_DIR" && printf 'y\n\n\n' | python3 wadfusion.py -v > "$WF_DIR/wadfusion.log" 2>&1) \
		|| { tail -n 20 "$WF_DIR/wadfusion.log"; die "wadfusion.py failed - full log: $WF_DIR/wadfusion.log"; }

	[[ -f "$WF_DIR/doom_fusion.ipk3" ]] || die "wadfusion finished but doom_fusion.ipk3 is missing - check $WF_DIR/wadfusion.log"
	cp -f "$WF_DIR/doom_fusion.ipk3" "$ROOT/iwads/"
	cp -f "$WF_DIR/doom_fusion_widescreen_gfx.pk3" "$ROOT/iwads/" 2>/dev/null || true
	ok "doom_fusion.ipk3 -> $ROOT/iwads/"
}

#------------------------------------------------------------------------------
# 10. Seed DoomRunner options.json (create or merge, backup first)
#------------------------------------------------------------------------------
seed_doomrunner_config() {
	step "Configuring DoomRunner"
	# DoomRunner >= 1.9 keeps options.json in its AppData dir (~/.local/share),
	# NOT ~/.config - it only migrates old locations when no target exists yet.
	local appdata_dir="$HOME/.local/share/DoomRunner"
	local cfg_dir="${CFG_DIR:-$appdata_dir}"
	local cfg="${CFG:-$cfg_dir/options.json}"
	if pgrep -f -i "DoomRunner.*[Aa]pp[Ii]mage|/[Dd]oomrunner$" | grep -qv $$; then
		warn "DoomRunner is running - it would overwrite options.json on exit."
		die "close DoomRunner first, then re-run this script"
	fi
	# retire a config seeded at the wrong (pre-1.9) location, so the app cannot
	# migrate it over the live one later
	if [[ -f "$HOME/.config/DoomRunner/options.json" ]]; then
		mv "$HOME/.config/DoomRunner/options.json" \
		   "$HOME/.config/DoomRunner/options.json.stale.$(date +%Y%m%d-%H%M%S)"
		warn "retired stale ~/.config/DoomRunner/options.json"
	fi
	mkdir -p "$cfg_dir"
	if [[ -f "$cfg" ]]; then
		local backup="$cfg.bak.$(date +%Y%m%d-%H%M%S)"
		cp "$cfg" "$backup"
		warn "existing options.json backed up to $backup"
	fi

	ROOT="$ROOT" WRAPPER="$UZDOOM_WRAPPER" CFG="$cfg" CFG_DIR="$cfg_dir" \
	DR_VERSION="${DR_TAG#v}" \
	python3 <<'PYEOF'
import copy, json, os
from pathlib import Path

root    = Path(os.environ["ROOT"])
wrapper = os.environ["WRAPPER"]
cfg     = Path(os.environ["CFG"])
dr_ver  = os.environ.get("DR_VERSION", "1.9.2")
var_dir = Path.home() / ".var/app/org.zdoom.UZDoom/config/ZDoom"

# full schema as the 1.9.x GUI serializes it (UserData.cpp / OptionsSerializer.cpp).
# a file WITHOUT "version" is routed to the pre-1.7 compat loader
# (OptionsSerializer.cpp:478) which expects entirely different keys, and the
# <1.9.2 migration reinterprets engine IDs as executable paths -> "engine was
# removed from the list" dialogs. so: complete skeleton + version stamp.
DEFAULTS = {
    "version": dr_ver,
    "engines": { "default_engine": "", "engine_list": [] },
    "IWADs":   { "auto_update": False, "directory": "", "search_subdirs": False, "default_iwad": "" },
    "maps":    { "directory": "", "sort_column": 0, "sort_order": 0, "show_icons": True },
    "mods":    { "last_used_dir": "", "show_icons": True },
    "launch_options": { "launch_mode": 0, "map_name": "", "save_file": "", "map_name_demo": "",
                        "demo_file_record": "", "demo_file_replay": "",
                        "demo_file_resume_from": "", "demo_file_resume_to": "" },
    "multiplayer_options": { "is_multiplayer": False, "mult_role": 0, "host_name": "", "port": 5029,
                             "net_mode": 0, "game_mode": 0, "player_count": 2, "team_damage": 0,
                             "time_limit": 0, "frag_limit": 0, "player_name": "", "player_color": None },
    "gameplay_options": { "skill_idx": 1, "skill_num": 1, "no_monsters": False, "fast_monsters": False,
                          "monsters_respawn": False, "pistol_start": False, "allow_cheats": False,
                          "dmflags1": 0, "dmflags2": 0, "dmflags3": 0 },
    "compatibility_options": { "compat_mode": -1, "compatflags1": 0, "compatflags2": 0 },
    "video_options": { "monitor_idx": 0, "resolution_x": None, "resolution_y": None, "show_fps": False },
    "audio_options": { "no_sound": False, "no_sfx": False, "no_music": False },
    "global_options": { "use_preset_name_as_config_dir": False, "use_preset_name_as_save_dir": False,
                        "use_preset_name_as_demo_dir": False, "use_preset_name_as_screenshot_dir": False,
                        "additional_args": "", "cmd_prefix": "", "env_vars": {} },
    "options_storage": { "launch_opts": 1, "gameplay_opts": 1, "compat_opts": 1, "video_opts": 1, "audio_opts": 1 },
    "use_absolute_paths": True,
    "show_engine_output": True,
    "close_on_launch": False,
    "close_output_on_success": False,
    "check_for_updates": True,
    "ask_for_sandbox_permissions": True,
    "wrap_lines_in_txt_viewer": True,
    "geometry": { "x": 900, "y": 235, "width": 760, "height": 760 },
    "app_style": None,
    "color_scheme": "default",
    "preset_search": { "panel_expanded": False, "case_sensitive": False, "use_regex": False },
    "hide_map_label": False,
    "presets": [],
    "selected_preset": "",
}

def fill_missing(dst, src):
    for k, v in src.items():
        if k not in dst:
            dst[k] = copy.deepcopy(v)
        elif isinstance(dst[k], dict) and isinstance(v, dict):
            fill_missing(dst[k], v)

data = {}
if cfg.exists():
    try:
        data = json.loads(cfg.read_text())
    except Exception:
        data = {}
if isinstance(data, dict):
    fill_missing(data, DEFAULTS)
else:
    data = copy.deepcopy(DEFAULTS)

engines = data.setdefault("engines", {})
engine_list = engines.setdefault("engine_list", [])
engine_id = "uzdoom-flatpak"
if not any(e.get("path") == wrapper or e.get("id") == engine_id for e in engine_list if isinstance(e, dict)):
    engine_list.append({
        "id":         engine_id,
        "name":       "UZDoom (Flatpak)",
        "path":       wrapper,
        "config_dir": str(var_dir),
        "data_dir":   str(var_dir),
        "family":     "ZDoom",
    })
engines["default_engine"] = engine_id

iwads = data.setdefault("IWADs", {})
iwads["auto_update"]     = True
iwads["directory"]       = str(root / "iwads")
iwads["search_subdirs"]  = True

data.setdefault("maps", {})["directory"] = str(root / "mods" / "Maps")
data.setdefault("mods", {})["last_used_dir"] = str(root / "mods" / "Mods")

# per-preset isolation: each preset gets its own config and save dirs
gopts = data.setdefault("global_options", {})
for k in ("use_preset_name_as_config_dir", "use_preset_name_as_save_dir",
          "use_preset_name_as_demo_dir", "use_preset_name_as_screenshot_dir"):
    gopts[k] = True

# DoomRunner resolves relative paths against its CWD - for the AppImage that
# is the ephemeral /tmp/.mount_* dir - so preset IWADs must be absolute
data["use_absolute_paths"] = True

iwads_dir = root / "iwads"
by_lower = {}
if iwads_dir.is_dir():
    for f in iwads_dir.iterdir():
        if f.is_file():
            by_lower.setdefault(f.name.lower(), str(f))

# full preset schema as the GUI writes it - partial presets make DoomRunner
# log "Element ... is missing in options.json" warnings on the next startup
def full_preset(name, iwad, mods=None):
    return {
        "name":              name,
        "selected_engine":   engine_id,
        "selected_config":   "",
        "selected_IWAD":     iwad,
        "selected_mappacks": [],
        "mods":              [{"checked": True, "path": m} for m in (mods or [])],
        "load_maps_after_mods": False,
        "compatibility_options": {"compat_mode": -1, "compatflags1": 0, "compatflags2": 0},
        "alternative_paths": {"config_dir": "", "save_dir": "", "demo_dir": "", "screenshot_dir": ""},
        "additional_args":   "",
        "env_vars":          {},
    }

presets = data.setdefault("presets", [])

# repair presets seeded by older script versions (or clobbered by DoomRunner's
# <1.9.2 migration): complete missing fields, rebind IWADs that got absolutized
# into a dead /tmp/.mount_* AppImage dir, and re-point engine selections that
# DoomRunner cleared/invalidated onto the engine we manage
known_ids = {e.get("id") for e in engine_list if isinstance(e, dict)}
for p in presets:
    if not isinstance(p, dict) or p.get("separator"):
        continue
    compat = p.setdefault("compatibility_options", {})
    for k, v in (("compat_mode", -1), ("compatflags1", 0), ("compatflags2", 0)):
        compat.setdefault(k, v)
    alt = p.setdefault("alternative_paths", {})
    for k in ("config_dir", "save_dir", "demo_dir", "screenshot_dir"):
        alt.setdefault(k, "")
    sel = p.get("selected_IWAD") or ""
    if sel and not Path(sel).is_file():
        reborn = by_lower.get(Path(sel).name.lower())
        if reborn:
            p["selected_IWAD"] = reborn
            print("rebound", p.get("name"), "->", reborn)
    eng = p.get("selected_engine")
    if not eng or eng not in known_ids:
        p["selected_engine"] = engine_id
        if eng != engine_id:
            print("re-engineered", p.get("name"), "(was", eng or "empty", ")")

if not any(p.get("name") == "DOOM Fusion" for p in presets if isinstance(p, dict)):
    presets.append(full_preset("DOOM Fusion", str(iwads_dir / "doom_fusion.ipk3")))

# one preset per other game whose IWAD is present in the iwads dir
for game, candidates in [
    ("Heretic",            ["heretic.wad"]),
    ("Hexen",              ["hexen.wad"]),
    ("Strife",             ["strife1.wad", "sve.wad"]),
    ("Chex Quest",         ["chex.wad"]),
    ("Chex Quest 3",       ["chex3.wad"]),
    ("Freedoom Phase 1",   ["freedoom1.wad"]),
    ("Freedoom Phase 2",   ["freedoom2.wad"]),
    ("Blasphemer",         ["blasphemer.wad"]),
]:
    for cand in candidates:
        if cand in by_lower:
            if not any(p.get("name") == game for p in presets if isinstance(p, dict)):
                presets.append(full_preset(game, by_lower[cand]))
            break

# one preset per mod folder (mods/Mods/<name>), bundling that folder's
# top-level pk3/wad/deh files - ready-made presets for touch-friendly use.
# selected_IWAD stays empty (pick the game once in the GUI); existing
# presets are never touched and folders without loadable files are skipped
mods_lib = root / "mods" / "Mods"
if mods_lib.is_dir():
    mod_ext = {".pk3", ".wad", ".deh"}
    made = 0
    for sub in sorted((d for d in mods_lib.iterdir()
                       if d.is_dir() and not d.name.startswith(".")),
                      key=lambda d: d.name.lower()):
        files = sorted((f for f in sub.iterdir()
                        if f.is_file() and f.suffix.lower() in mod_ext),
                       key=lambda f: f.name.lower())
        if not files or any(p.get("name") == sub.name for p in presets if isinstance(p, dict)):
            continue
        presets.append(full_preset(sub.name, "", [str(f) for f in files]))
        made += 1
    if made:
        print(f"added {made} mod-folder preset(s)")

data["selected_preset"] = "DOOM Fusion"

# re-stamp: without it the next launch falls into the pre-1.7 compat loader
data["version"] = dr_ver

cfg.write_text(json.dumps(data, indent="\t") + "\n")
print("wrote", cfg)
PYEOF
	ok "engine + directories + 'DOOM Fusion' + per-game presets configured"
}

#------------------------------------------------------------------------------
# 11. Steam "non-Steam game" shortcut (binary shortcuts.vdf) + grid art
#------------------------------------------------------------------------------
fetch_steam_art() {
	# a single-file curl install has no steam_art/ beside the script -> pull
	# the grid art from the repo. fetched only when the folder never existed:
	# once present (even with files deleted by the user) it is left alone.
	[[ -d "$STEAM_ART_DIR" ]] && return 0
	mkdir -p "$STEAM_ART_DIR"
	local f n=0
	for f in hero.png logo.png capsule.png capsule_p.png icon.png layout.json; do
		if curl -fsSL --retry 2 -o "$STEAM_ART_DIR/$f.part" "$STEAM_ART_BASE/$f" 2>/dev/null; then
			mv -f "$STEAM_ART_DIR/$f.part" "$STEAM_ART_DIR/$f" && n=$((n + 1))
		fi
	done
	rm -f "$STEAM_ART_DIR"/*.part
	if (( n )); then
		ok "steam grid art fetched from the repo ($n/6 files)"
	else
		warn "could not fetch steam_art - the shortcut will use Steam's default icon (harmless)"
	fi
}

add_steam_shortcut() {
	step "Adding DoomRunner to Steam"
	fetch_steam_art
	local steam_dir="" d running=0 rc
	for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/debian-installation"; do
		[[ -d "$d/userdata" ]] && { steam_dir="$d"; break; }
	done
	if [[ -z "$steam_dir" ]]; then
		warn "no Steam install found - add DoomRunner manually: Steam -> Games -> Add a Game"
		return 0
	fi
	# Steam keeps shortcuts.vdf in memory and rewrites it on exit
	pgrep -x steam          >/dev/null 2>&1 && running=1
	pgrep -x steamwebhelper >/dev/null 2>&1 && running=1

	if STEAM_DIR="$steam_dir" RUNNER_BIN="$RUNNER_BIN" ART_DIR="$STEAM_ART_DIR" \
	   WRITE=$(( running ? 0 : 1 )) python3 <<'PYEOF'
import os, shutil, struct, sys, time, zlib
from pathlib import Path

steam_dir = Path(os.environ["STEAM_DIR"])
runner    = os.environ["RUNNER_BIN"]
art_dir   = Path(os.environ["ART_DIR"])
write     = os.environ.get("WRITE") == "1"
APPNAME   = "DoomRunner"

# grid/<appid><suffix>  <-  steam_art/<file>
ART_MAP = {
    "hero.png":      "_hero.png",
    "logo.png":      "_logo.png",
    "capsule.png":   ".png",
    "capsule_p.png": "p.png",
    "icon.png":      "_icon.png",
    "layout.json":   ".json",
}

def parse(data):
    pos = 0
    def rstr():
        nonlocal pos
        e = data.index(b"\0", pos)
        s = data[pos:e].decode("utf-8", "surrogateescape")
        pos = e + 1
        return s
    def obj():
        nonlocal pos
        out = {}
        while pos < len(data):
            t = data[pos]; pos += 1
            if t == 8:
                return out
            k = rstr()
            if   t == 0:    out[k] = obj()
            elif t == 1:    out[k] = rstr()
            elif t == 2:    out[k] = struct.unpack_from("<i", data, pos)[0]; pos += 4
            elif t == 4:    out[k] = struct.unpack_from("<Q", data, pos)[0]; pos += 8
            elif t == 0x0B: out[k] = struct.unpack_from("<q", data, pos)[0]; pos += 8
            else:           raise ValueError("unsupported vdf type %#x at %r" % (t, k))
        raise ValueError("unterminated vdf section")
    root = obj()
    if pos != len(data):
        raise ValueError("trailing bytes after vdf root")
    return root

def ser(obj, out):
    for k, v in obj.items():
        kb = k.encode("utf-8", "surrogateescape")
        if isinstance(v, dict):
            out += b"\x00" + kb + b"\x00"; ser(v, out); out += b"\x08"
        elif isinstance(v, str):
            out += b"\x01" + kb + b"\x00" + v.encode("utf-8", "surrogateescape") + b"\x00"
        elif isinstance(v, int):
            if -(2**31) <= v < 2**31: out += b"\x02" + kb + b"\x00" + struct.pack("<i", v)
            else:                     out += b"\x0B" + kb + b"\x00" + struct.pack("<q", v)
        else:
            raise ValueError("unsupported value type %r" % type(v))

exe_quoted = f'"{runner}"'
profiles = [p / "config" for p in sorted((steam_dir / "userdata").glob("[0-9]*")) if (p / "config").is_dir()]
if not profiles:
    print("no Steam user profiles found", file=sys.stderr)
    sys.exit(4)

# pass 1: is the shortcut already there? (safe while Steam runs)
results, appid = [], None
for cfg_dir in profiles:
    f = cfg_dir / "shortcuts.vdf"
    root = parse(f.read_bytes()) if f.is_file() else {"shortcuts": {}}
    hit = next((s for s in root.get("shortcuts", {}).values()
                if isinstance(s, dict) and (s.get("appname") == APPNAME
                    or s.get("exe", "").strip('"') == runner)), None)
    results.append((cfg_dir, root, hit))
    if hit is not None and appid is None:
        appid = int(hit.get("appid", 0)) & 0xFFFFFFFF

if appid is None and not write:
    print("shortcut missing and Steam is running - not writing")
    sys.exit(3)

ts = time.strftime("%Y%m%d-%H%M%S")
if appid is None:
    # Steam marks non-Steam games with the high bit set; the exact value only
    # has to be stable (grid art is looked up by this number)
    appid = (zlib.crc32((exe_quoted + APPNAME).encode()) & 0xFFFFFFFF) | 0x80000000

# a bundled 1024px icon.png becomes the entry icon for newly added shortcuts
icon_path = str(profiles[0] / "grid" / f"{appid}_icon.png") if (art_dir / "icon.png").is_file() else ""

entry = {
    "appid":         appid - 0x100000000 if appid >= 0x80000000 else appid,
    "appname":       APPNAME,
    "exe":           exe_quoted,
    "StartDir":      str(Path(runner).parent) + "/",
    "icon":          icon_path,
    "ShortcutPath":  "",
    "LaunchOptions": "",
    "IsHidden":      0,
    "AllowDesktopConfig": 1,
    "AllowOverlay":  1,
    "OpenVR":        0,
    "Devkit":        0,
    "DevkitGameID":  "",
    "DevkitOverrideAppID": 0,
    "LastPlayTime":  0,
    "FlatpakAppID":  "",
    "sortas":        "",
    "tags":          {},
}

# pass 2: add to profiles missing it / refresh exe after an AppImage upgrade
added = updated = 0
for cfg_dir, root, hit in results:
    changed = False
    if hit is None:
        scs = root.setdefault("shortcuts", {})
        scs[str(max((int(k) for k in scs if k.isdigit()), default=-1) + 1)] = dict(entry)
        added += 1
        changed = True
    elif write and hit.get("exe") != exe_quoted:
        hit["exe"] = exe_quoted                      # keep appid -> art survives
        hit["StartDir"] = str(Path(runner).parent) + "/"
        updated += 1
        changed = True
    if changed and write:
        f = cfg_dir / "shortcuts.vdf"
        if f.is_file():
            shutil.copy2(f, f.with_name(f.name + ".bak." + ts))
        buf = bytearray()
        ser(root, buf)
        buf += b"\x08"  # the whole file is a section too - close it
        tmp = f.with_name(f.name + ".tmp")
        tmp.write_bytes(bytes(buf))
        os.replace(tmp, f)

# grid art (copy is content-checked, safe to run alongside Steam)
copied = 0
if appid is not None and art_dir.is_dir():
    for cfg_dir, _, _ in results:
        grid = cfg_dir / "grid"
        for src, suffix in ART_MAP.items():
            s = art_dir / src
            if not s.is_file():
                continue
            grid.mkdir(exist_ok=True)
            dst = grid / f"{appid}{suffix}"
            if not dst.exists() or dst.stat().st_size != s.stat().st_size:
                shutil.copy2(s, dst)
                copied += 1

print(f"appid={appid} added={added} updated={updated} art_copied={copied} profiles={len(profiles)}")
PYEOF
	then rc=0; else rc=$?; fi

	case "$rc" in
		0) ok "Steam shortcut in place (idempotent, per user profile)" ;;
		3) warn "Steam is running - it would overwrite shortcuts.vdf on exit."
		   warn "quit Steam (tray icon -> Exit Steam) and re-run this script to add the shortcut." ;;
		*) die "could not update Steam shortcuts (rc=$rc)" ;;
	esac
}

#------------------------------------------------------------------------------
# 12. Verification + summary
#------------------------------------------------------------------------------
verify() {
	step "Verifying"
	local ver
	ver=$(flatpak run "$UZDOOM_APP_ID" -version 2>/dev/null | head -n1) \
		&& ok "$ver" || warn "uzdoom -version failed - check 'flatpak run $UZDOOM_APP_ID -version'"

	if flatpak run --command=ls "$UZDOOM_APP_ID" "$ROOT/mods/Maps" >/dev/null 2>&1; then
		ok "UZDoom sandbox can read $ROOT (recursively)"
	else
		warn "sandbox could not list $ROOT/mods/Maps - check Flatseal / 'flatpak overrides $UZDOOM_APP_ID'"
	fi

	if [[ -f "$ROOT/iwads/doom_fusion.ipk3" ]] && python3 -c "
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1])
bad = z.testzip()
assert bad is None, bad
" "$ROOT/iwads/doom_fusion.ipk3" 2>/dev/null; then
		ok "doom_fusion.ipk3 is a valid archive ($(du -h "$ROOT/iwads/doom_fusion.ipk3" | cut -f1))"
	else
		warn "doom_fusion.ipk3 missing or corrupt - rerun with --force"
	fi

	local game_wads
	game_wads=$(find "$ROOT/iwads" -maxdepth 1 -type f \( -iname '*.wad' -o -iname '*.ipk3' \) \
		| sed "s|.*/||" | sort | paste -sd' ' -)
	ok "IWADs in place: ${game_wads:-none}"

	step "Done - next steps"
	cat <<EOF
  * Launch DoomRunner: double-click ${RUNNER_BIN:-the AppImage in "$ROOT"}
    (or run it from a terminal). The 'DOOM Fusion' preset is preselected;
    pick the Heretic / Hexen / Strife / Chex / Freedoom / Blasphemer presets
    (added for every IWAD found) to play the other games.
  * Steam library: DoomRunner is added automatically as a non-Steam game
    (restart Steam or switch to Gaming mode to see it; skip this line if
    Steam was running during install - re-run this script after quitting it).
  * Browse mods with DoomRunner: Mods dir = $ROOT/mods/Mods,
    Maps dir  = $ROOT/mods/Maps  (both preconfigured).
  * Review UZDoom permissions any time with Flatseal.
  * The uzdoom wrapper sets gamescope's GAMESCOPE_COMPOSITE_FORCE=1 when a
    display is present, working around the Steam Game Mode scanout glitch
    (ValveSoftware/gamescope#1368). Harmless in Desktop mode.
EOF
}

#------------------------------------------------------------------------------
# main
#------------------------------------------------------------------------------
main() {
	printf '%s=== Ultimate Doom installer for SteamOS and Linux ===%s\n' "$C_STEP" "$C_OFF"
	preflight
	ask_root
	install_uzdoom
	install_doomrunner
	make_wrapper
	grant_permissions
	setup_wadfusion
	install_extras
	seed_doomrunner_config
	add_steam_shortcut
	verify
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
