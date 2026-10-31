#!/usr/bin/env bash
#
# serpantinum-update.sh
#
# Every run: pulls the newest upstream, shows the original installer banner/menu,
# then deploys ONLY bin/ and src/ into ~/.local/share/serpantinum, merges
# settings.json, and writes the version state file.
#
# It never touches: compositor configs, kitty/cava/fastfetch/matugen configs,
# packages, services, SDDM, wallpapers, first_launch.done, /usr/local/bin.
#
# Usage:   serpantinum-update.sh [-y|--yes]      (-y skips the menu)
# Env:     REPO_SLUG=you/fork   SERPANTINUM_BRANCH=name   SERPANTINUM_REPO_URL=url

set -e

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
RAW_SLUG="${REPO_SLUG:-giotigioti/serpantinum}"
REPO_SLUG="$(printf '%s' "$RAW_SLUG" | tr -d '\r\n\t ' | sed 's/[^a-zA-Z0-9_\/-]//g')"
REPO_URL="${SERPANTINUM_REPO_URL:-git@github.com:${REPO_SLUG}.git}"
BRANCH="${SERPANTINUM_BRANCH:-HEAD}"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/serpantinum-update"
TARGET_BASE="$HOME/.local/share/serpantinum"
BIN_DIR="$HOME/.local/bin"

# Same location the shell itself uses (scripts/caching.sh exports this path).
STATE_DIR="$HOME/.local/state/serpantinum"
VERSION_FILE="$STATE_DIR/version"

CONFIG_DIR="$HOME/.config/serpantinum"
CONFIG_FILE="$CONFIG_DIR/settings.json"

ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
    esac
done

RESET=$'\e[0m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
C_BLUE=$'\e[34m'
C_CYAN=$'\e[36m'
C_GREEN=$'\e[32m'
C_YELLOW=$'\e[33m'
C_RED=$'\e[31m'
C_MAGENTA=$'\e[35m'

WARNINGS=()
SELECTED_COMPOSITORS=()
INSTALL_STATE="fresh"
TARGET_VERSION="unknown"
TARGET_COMMIT="unknown"
OLD_VERSION=""

info() { printf "%s[ INFO ]%s %s\n" "$C_CYAN" "$RESET" "$*"; }
ok()   { printf "%s[  OK  ]%s %s\n" "$C_GREEN" "$RESET" "$*"; }
warn() { printf "%s[ WARN ]%s %s\n" "$C_YELLOW" "$RESET" "$*"; WARNINGS+=("$*"); }
err()  { printf "%s[ FAIL ]%s %s\n" "$C_RED" "$RESET" "$*" >&2; }

cleanup_terminal() {
    printf "\e[?25h" 2>/dev/null || true
    stty echo icanon 2>/dev/null || true
}
trap cleanup_terminal EXIT INT TERM

# ----------------------------------------------------------------------------
# 1. Pull newest upstream (every run)
# ----------------------------------------------------------------------------
pull_latest() {
    if ! command -v git &>/dev/null; then
        err "git is required"
        exit 1
    fi

    if [ -d "$CACHE_DIR/.git" ]; then
        git -C "$CACHE_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
        if git -C "$CACHE_DIR" fetch --depth 1 origin "$BRANCH" 2>/dev/null; then
            git -C "$CACHE_DIR" reset --hard FETCH_HEAD >/dev/null 2>&1
            return 0
        fi
        warn "Could not reach $REPO_URL, using the previously downloaded copy"
        return 0
    fi

    rm -rf "$CACHE_DIR"
    mkdir -p "$(dirname "$CACHE_DIR")"
    if [ "$BRANCH" = "HEAD" ]; then
        git clone --depth 1 "$REPO_URL" "$CACHE_DIR" || { err "clone failed: $REPO_URL"; exit 1; }
    else
        git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$CACHE_DIR" || { err "clone failed: $REPO_URL ($BRANCH)"; exit 1; }
    fi
    return 0
}

info "Fetching the latest version from $REPO_URL ..."
pull_latest

if [ ! -d "$CACHE_DIR/src" ]; then
    err "Downloaded repo has no src/ directory, aborting"
    exit 1
fi

# i18n comes from the freshly pulled repo, so the UI text always matches upstream
export SERPANTINUM_DIR="$CACHE_DIR/src"
export I18N_DIR="$CACHE_DIR/src/assets/languages"
if [ -f "$CACHE_DIR/src/scripts/i18n.sh" ]; then
    # shellcheck disable=SC1091
    source "$CACHE_DIR/src/scripts/i18n.sh"
fi
if ! declare -f t >/dev/null; then
    t() { printf '%s' "$1"; }
fi

# ----------------------------------------------------------------------------
# Version helpers
# ----------------------------------------------------------------------------
read_state() {
    if [ -f "$VERSION_FILE" ]; then
        awk -F= -v k="$1" '$1==k{gsub(/"/, "", $2); print $2; exit}' "$VERSION_FILE"
    fi
    return 0
}

load_versions() {
    if [ -f "$CACHE_DIR/version.txt" ]; then
        TARGET_VERSION="$(head -n 1 "$CACHE_DIR/version.txt" 2>/dev/null | xargs || true)"
    fi
    [ -n "$TARGET_VERSION" ] || TARGET_VERSION="unknown"

    TARGET_COMMIT="$(git -C "$CACHE_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    [ -n "$TARGET_COMMIT" ] || TARGET_COMMIT="unknown"

    OLD_VERSION="$(read_state SERPANTINUM_VERSION)"

    if [ -f "$VERSION_FILE" ]; then
        INSTALL_STATE="current"
    else
        INSTALL_STATE="fresh"
    fi
    return 0
}

write_version_state() {
    mkdir -p "$STATE_DIR"
    local tmp_file="${VERSION_FILE}.tmp.$$"
    cat > "$tmp_file" <<EOF
SERPANTINUM_VERSION="$TARGET_VERSION"
SERPANTINUM_COMMIT="$TARGET_COMMIT"
SELECTED_COMPOSITORS="${SELECTED_COMPOSITORS[*]}"
EOF
    mv -f "$tmp_file" "$VERSION_FILE"
}

# ----------------------------------------------------------------------------
# Compositor detection (only used to record SELECTED_COMPOSITORS in the version
# file, exactly like the stock installer; nothing is deployed for it)
# ----------------------------------------------------------------------------
detect_compositor() {
    local running=""
    local de="${XDG_CURRENT_DESKTOP,,}"
    local session="${DESKTOP_SESSION,,}"

    if [[ -n "$MANGO_INSTANCE_SIGNATURE" ]] || pgrep -x "mango" &>/dev/null || [[ "$de" == *"mango"* ]] || [[ "$session" == *"mango"* ]]; then
        running="mango"
    elif [[ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]] || pgrep -x "Hyprland" &>/dev/null || pgrep -x "hyprland" &>/dev/null || [[ "$de" == *"hyprland"* ]] || [[ "$session" == *"hyprland"* ]]; then
        running="hyprland"
    elif [[ -n "$SWAYSOCK" ]] || pgrep -x "sway" &>/dev/null || [[ "$de" == *"sway"* ]] || [[ "$session" == *"sway"* ]]; then
        running="sway"
    elif pgrep -x "niri" &>/dev/null || [[ "$de" == *"niri"* ]] || [[ "$session" == *"niri"* ]]; then
        running="niri"
    fi

    if [ -n "$running" ]; then
        SELECTED_COMPOSITORS=("$running")
        return 0
    fi

    local saved
    saved="$(read_state SELECTED_COMPOSITORS)"
    if [ -n "$saved" ]; then
        read -r -a SELECTED_COMPOSITORS <<< "$saved"
        return 0
    fi

    local installed=() comp
    for comp in hyprland niri sway mango; do
        if command -v "$comp" &>/dev/null; then
            installed+=("$comp")
        fi
    done
    if [ ${#installed[@]} -eq 1 ]; then
        SELECTED_COMPOSITORS=("${installed[0]}")
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Original installer UI (banner, key reader, menu, completion screen)
# ----------------------------------------------------------------------------
collect_sysinfo() {
    USER_NAME="${USER:-$(whoami)}"
    OS_NAME=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    [[ -z "$OS_NAME" ]] && OS_NAME="$(t "installer.os.default_os")"
    CPU_INFO=$(grep -m 1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || true)
    [[ -z "$CPU_INFO" ]] && CPU_INFO="$(t "installer.os.unknown_cpu")"
    local gpu_raw
    gpu_raw=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' || true)
    GPU_INFO=$(echo "$gpu_raw" | cut -d: -f3 | sed -E 's/ \(rev [0-9a-f]+\)//g' | xargs || true)
    [[ -z "$GPU_INFO" ]] && GPU_INFO="$(t "installer.os.unknown_gpu")"
    return 0
}

read_key() {
    local key=""
    local rest=""
    IFS= read -rsn1 key 2>/dev/null
    if [[ "$key" == $'\x1b' ]]; then
        read -rsn2 -t 0.05 rest 2>/dev/null
        if [[ "$rest" == "[A" || "$rest" == "OA" ]]; then
            echo "UP"
            return
        elif [[ "$rest" == "[B" || "$rest" == "OB" ]]; then
            echo "DOWN"
            return
        elif [[ "$rest" == "[C" || "$rest" == "OC" ]]; then
            echo "RIGHT"
            return
        elif [[ "$rest" == "[D" || "$rest" == "OD" ]]; then
            echo "LEFT"
            return
        elif [[ "$rest" == *"["* ]]; then
            local trailing=""
            while read -rsn1 -t 0.05 trailing 2>/dev/null; do
                [[ -z "$trailing" ]] && break
            done
            echo "ESC"
            return
        fi
        echo "ESC"
        return
    elif [[ -z "$key" || "$key" == $'\n' || "$key" == $'\r' ]]; then
        echo "ENTER"
        return
    elif [[ "$key" == " " ]]; then
        echo "SPACE"
        return
    fi
    echo "$key"
}

draw_banner() {
    clear
    printf "%s%s" "$BOLD" "$C_CYAN"
    cat << "EOF"
███████╗███████╗██████╗ ██████╗  █████╗ ███╗   ██╗████████╗██╗███╗   ██╗██╗   ██╗███╗   ███╗
██╔════╝██╔════╝██╔══██╗██╔══██╗██╔══██╗████╗  ██║╚══██╔══╝██║████╗  ██║██║   ██║████╗ ████║
███████╗█████╗  ██████╔╝██████╔╝███████║██╔██╗ ██║   ██║   ██║██╔██╗ ██║██║   ██║██╔████╔██║
╚════██║██╔══╝  ██╔══██╗██╔═══╝ ██╔══██║██║╚██╗██║   ██║   ██║██║╚██╗██║██║   ██║██║╚██╔╝██║
███████║███████╗██║  ██║██║     ██║  ██║██║ ╚████║   ██║   ██║██║ ╚████║╚██████╔╝██║ ╚═╝ ██║
╚══════╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝   ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝     ╚═╝
EOF
    printf "%s\n" "$RESET"

    local OSC8_GH=$'\e]8;;https://github.com/'"${REPO_SLUG}"$'\a'
    local OSC8_TW=$'\e]8;;https://twitter.com/ilyamirox\a'
    local OSC8_RD=$'\e]8;;https://reddit.com/u/ilyamiro1\a'
    local OSC8_TG=$'\e]8;;https://t.me/stewart_github\a'
    local OSC8_KF=$'\e]8;;https://ko-fi.com/ilyamiro\a'
    local OSC8_END=$'\e]8;;\a'

    printf "\033[K%s--------------------------------------------------------------------------------%s\n" "$C_BLUE" "$RESET"
    printf "\033[K%s%s $(t "installer.ui.github")%s   %shttps://github.com/%s%s\n" "$BOLD" "$C_GREEN" "$RESET" "$OSC8_GH" "$REPO_SLUG" "$OSC8_END"
    printf "\033[K%s%s $(t "installer.ui.twitter")%s  %s@ilyamirox%s  |  %s%s$(t "installer.ui.reddit")%s %su/ilyamiro1%s\n" "$BOLD" "$C_CYAN" "$RESET" "$OSC8_TW" "$OSC8_END" "$BOLD" "$C_RED" "$RESET" "$OSC8_RD" "$OSC8_END"
    printf "\033[K%s%s $(t "installer.ui.telegram")%s %shttps://t.me/serpantinum_git%s\n" "$BOLD" "$C_BLUE" "$RESET" "$OSC8_TG" "$OSC8_END"
    printf "\033[K%s%s $(t "installer.ui.donate")%s   %shttps://ko-fi.com/ilyamiro $(t "installer.ui.donate_sub")%s\n" "$BOLD" "$C_MAGENTA" "$RESET" "$OSC8_KF" "$OSC8_END"
    printf "\033[K%s--------------------------------------------------------------------------------%s\n" "$C_BLUE" "$RESET"
    printf "\033[K%s $(t "installer.ui.user")%s %-25s | %s$(t "installer.ui.os")%s %s\n" "$BOLD" "$RESET" "$USER_NAME" "$BOLD" "$RESET" "$OS_NAME"
    printf "\033[K%s $(t "installer.ui.cpu")%s  %-25s | %s$(t "installer.ui.gpu")%s %s\n" "$BOLD" "$RESET" "$CPU_INFO" "$BOLD" "$RESET" "$GPU_INFO"
    printf "\033[K%s--------------------------------------------------------------------------------%s\n" "$C_BLUE" "$RESET"
    printf "\033[K%s $(t "installer.ui.target_version")%s %-10s (%-7s) | %s$(t "installer.ui.install_mode")%s %s\n" "$BOLD" "$RESET" "$TARGET_VERSION" "$TARGET_COMMIT" "$BOLD" "$RESET" "$INSTALL_STATE"
    printf "\033[K%s================================================================================%s\n\n" "$C_BLUE" "$RESET"
}

run_installer_ui() {
    local cursor=0
    local rendered_lines=0

    draw_banner
    stty -echo 2>/dev/null || true
    printf "\e[?25l"

    while true; do
        local items=()
        if [[ "$INSTALL_STATE" == "current" ]]; then
            items+=("1. ${BOLD}${C_GREEN}$(t "installer.ui.menu_update")${RESET}")
        else
            items+=("1. ${BOLD}${C_GREEN}$(t "installer.ui.menu_install")${RESET}")
        fi
        items+=("2. ${DIM}$(t "installer.ui.menu_exit")${RESET}")

        if [ "$rendered_lines" -gt 0 ]; then
            printf "\033[%dA" "$rendered_lines"
        fi
        local i
        for i in "${!items[@]}"; do
            if [ "$i" -eq "$cursor" ]; then
                printf "\r\033[K%s%s ▸ %s%s\n" "$BOLD" "$C_CYAN" "$RESET" "${items[$i]}"
            else
                printf "\r\033[K    %s\n" "${items[$i]}"
            fi
        done
        rendered_lines=${#items[@]}

        local key
        key=$(read_key)

        case "$key" in
            UP|[kK])
                if [ "$cursor" -gt 0 ]; then cursor=$(( cursor - 1 )); else cursor=$(( ${#items[@]} - 1 )); fi
                ;;
            DOWN|[jJ])
                if [ "$cursor" -lt $(( ${#items[@]} - 1 )) ]; then cursor=$(( cursor + 1 )); else cursor=0; fi
                ;;
            "1")
                cleanup_terminal
                return 0
                ;;
            "2"|ESC|[qQ])
                cleanup_terminal
                clear
                exit 0
                ;;
            ENTER|SPACE)
                if [ "$cursor" -eq 0 ]; then
                    cleanup_terminal
                    return 0
                fi
                cleanup_terminal
                clear
                exit 0
                ;;
        esac
    done
}

draw_completion_screen() {
    cleanup_terminal
    clear 2>/dev/null || true
    printf "%s%s" "$BOLD" "$C_GREEN"
    cat << "EOF"
 ___ _  _ ___ _____ _   _     _ _____ ___ ___  _  _    ___ ___  __  __ ___ _    ___ _____ ___ 
|_ _| \| / __|_   _/_\ | |   /_\_   _|_ _/ _ \| \| |  / __/ _ \ | \/  | _ \ |  | __|_   _| __|
 | || .` \__ \ | |/ _ \| |__| _ \| |  | | (_) | .` | | (_| (_) | |\/| |  _/ |__| _|  | | | _| 
|___|_|\_|___/ |_/_/ \_\____/_/ \_\_| |___\___/|_|\_|  \___\___/|_|  |_|_| |____|___| |_| |___|
EOF
    printf "%s\n\n" "$RESET"
    printf "%s%s  %s%s\n\n" "$BOLD" "$C_CYAN" "$(t "installer.ui.tagline")" "$RESET"
    printf "%s%s================================================================================%s\n" "$BOLD" "$C_MAGENTA" "$RESET"
    printf "%s%s $(t "installer.ui.support_creator")%s\n" "$BOLD" "$C_YELLOW" "$RESET"
    printf " $(t "installer.ui.buy_coffee")\n"
    printf " %s%sKo-fi:%s https://ko-fi.com/ilyamiro\n" "$BOLD" "$C_CYAN" "$RESET"
    printf "%s%s================================================================================%s\n\n" "$BOLD" "$C_MAGENTA" "$RESET"
    printf "%s%s%s\n" "$C_GREEN" "$(t "installer.ui.installed_success" "ver=$TARGET_VERSION" "commit=$TARGET_COMMIT")" "$RESET"
    print_warnings
}

print_warnings() {
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        printf "\n%s%sWarnings:%s\n" "$BOLD" "$C_YELLOW" "$RESET"
        local w
        for w in "${WARNINGS[@]}"; do
            printf "  - %s\n" "$w"
        done
    fi
    return 0
}

# ----------------------------------------------------------------------------
# 2. Deploy bin/ and src/ only (each swapped in via a staging dir)
# ----------------------------------------------------------------------------
deploy_files() {
    mkdir -p "$TARGET_BASE" "$BIN_DIR"

    local d
    for d in bin src; do
        local from="$CACHE_DIR/$d"
        if [ -d "$from" ] && [ -n "$(ls -A "$from" 2>/dev/null)" ]; then
            rm -rf "$TARGET_BASE/$d.new"
            mkdir -p "$TARGET_BASE/$d.new"
            cp -a "$from/." "$TARGET_BASE/$d.new/"
            rm -rf "$TARGET_BASE/$d"
            mv "$TARGET_BASE/$d.new" "$TARGET_BASE/$d"
        fi
    done

    chmod +x "$TARGET_BASE/bin/"* 2>/dev/null || true
    find "$TARGET_BASE/src/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

    local b
    for b in serpantinum serpantinumd; do
        if [ -f "$TARGET_BASE/bin/$b" ]; then
            ln -sf "$TARGET_BASE/bin/$b" "$BIN_DIR/$b"
        fi
    done

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR is not in your PATH, so 'serpantinumd' won't be found by name" ;;
    esac
    return 0
}

# PAM service used by the lockscreen. Created only if missing, never rewritten.
setup_pam_service() {
    local pam_dir="/etc/pam.d"
    local target="$pam_dir/serpantinum"
    local base="" candidate

    [ -d "$pam_dir" ] || return 0
    [ -e "$target" ] && return 0

    for candidate in system-auth login; do
        if [ -f "$pam_dir/$candidate" ]; then
            base="$candidate"
            break
        fi
    done
    [ -n "$base" ] || return 0

    local content=""
    if ! grep -qs "pam_fprintd" "$pam_dir/$base"; then
        content+="-auth       sufficient   pam_fprintd.so"$'\n'
    fi
    content+="auth        include      $base"$'\n'
    content+="account     include      $base"$'\n'

    if printf '%s' "$content" | sudo tee "$target" >/dev/null 2>&1; then
        sudo chmod 644 "$target" 2>/dev/null || true
    else
        warn "Could not create $target (needs sudo). The lockscreen may not authenticate."
    fi
    return 0
}

# ----------------------------------------------------------------------------
# 3. settings.json: merge template defaults UNDER your values, every run.
#    Your values always win; only keys you don't have yet are added.
# ----------------------------------------------------------------------------
default_wallpaper_dir() {
    local pics=""
    if [ -f "$HOME/.config/user-dirs.dirs" ]; then
        pics=$(grep '^XDG_PICTURES_DIR' "$HOME/.config/user-dirs.dirs" 2>/dev/null | cut -d= -f2 | tr -d '"' | sed "s|\$HOME|$HOME|g" || true)
    fi
    if [[ -z "$pics" || "$pics" == "$HOME" ]]; then
        pics="$HOME/Pictures"
    fi
    echo "${pics%/}/Wallpapers"
}

merge_settings() {
    local template="$CACHE_DIR/config/serpantinum/settings.json"
    mkdir -p "$CONFIG_DIR"

    if ! command -v jq &>/dev/null; then
        warn "jq not found, settings.json was not merged"
        return 1
    fi
    if [ ! -f "$template" ]; then
        warn "No settings template in the repo, settings.json was not merged"
        return 1
    fi

    local sys_lang="en"
    if declare -f detect_system_language >/dev/null; then
        sys_lang="$(detect_system_language)"
    fi
    local wp
    wp="$(default_wallpaper_dir)"
    local tmp="$CONFIG_FILE.tmp.$$"

    if [ -s "$CONFIG_FILE" ]; then
        if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
            warn "settings.json is not valid JSON, left untouched"
            return 1
        fi
        cp -f "$CONFIG_FILE" "$CONFIG_FILE.bak"
        jq -s --arg wp "$wp" --arg lang "$sys_lang" '
            (.[0] * .[1])
            | (if ((.wallpaperDir // "") == "") then .wallpaperDir = $wp else . end)
            | (if ((.general.language // null) == null) then .general.language = $lang else . end)
        ' "$template" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
    else
        jq --arg wp "$wp" --arg lang "$sys_lang" '
            (if ((.wallpaperDir // "") == "") then .wallpaperDir = $wp else . end)
            | (if ((.general.language // null) == null) then .general.language = $lang else . end)
        ' "$template" > "$tmp" 2>/dev/null || true
    fi

    if [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "$CONFIG_FILE"
    else
        rm -f "$tmp"
        warn "settings.json merge failed, left as it was (backup: settings.json.bak)"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
load_versions
collect_sysinfo
detect_compositor

if [ "$ASSUME_YES" != true ]; then
    run_installer_ui
fi

info "Deploying bin/ and src/ to $TARGET_BASE"
deploy_files
ok "Files deployed"

setup_pam_service

info "Merging settings.json"
if merge_settings; then
    ok "Settings merged"
fi

write_version_state
ok "Version state written ($TARGET_VERSION @ $TARGET_COMMIT)"

if [ "$ASSUME_YES" = true ]; then
    printf "\n%sUpdated %s -> %s (%s)%s\n" "$C_GREEN" "${OLD_VERSION:-none}" "$TARGET_VERSION" "$TARGET_COMMIT" "$RESET"
    print_warnings
else
    draw_completion_screen
fi
