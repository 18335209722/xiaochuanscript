#!/usr/bin/env bash
# 小川环境助手 · macOS / Linux 版
# 功能对齐 Windows 版 XiaochuanEnv 1.0.0：
#   清理 Claude Code 缓存 / 会话历史、清理 Chrome 缓存并设为 en-US、
#   时区改为 America/Los_Angeles、系统语言改为 en-US、安装 / 卸载 Claude。
# 兼容 macOS 自带的 bash 3.2：不使用关联数组、mapfile、${var,,} 等新语法。

VERSION="1.1.0"
TARGET_TZ="America/Los_Angeles"

case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux) OS="linux" ;;
    *) echo "只支持 macOS 和 Linux。" >&2; exit 1 ;;
esac

# 用 sudo 整个运行会把缓存清理、语言、键盘这些「用户级」操作做到 root 账户上，
# 还会把家目录里的文件变成 root 所有。所以这里退回原用户身份重新执行，
# 真正需要管理员权限的步骤（时区等）由脚本自己逐条 sudo；密码刚输过，不会再问。
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -f "$0" ]; then
    echo "检测到用 sudo 运行：改回用户 $SUDO_USER 的身份执行，需要管理员权限的步骤会自动提权。"
    exec sudo -u "$SUDO_USER" -H -- bash "$0" "$@"
fi

DATA_DIR="$HOME/.xiaochuan-env"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$DATA_DIR/backups/$STAMP"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CLAUDE_JSON="$CLAUDE_CONFIG_DIR/.claude.json"
else
    CLAUDE_JSON="$HOME/.claude.json"
fi

if [ "$OS" = "mac" ]; then
    CHROME_DATA="$HOME/Library/Application Support/Google/Chrome"
    CHROME_CACHE="$HOME/Library/Caches/Google/Chrome"
    CLI_CACHE="$HOME/Library/Caches/claude-cli-nodejs"
else
    CHROME_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome"
    CHROME_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/google-chrome"
    CLI_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-cli-nodejs"
fi

DRY_RUN=0
ASSUME_YES=0
FORCE=0
REMOVE_DATA=0
DO_CACHE=0
DO_HISTORY=0
DO_CHROME=0
DO_TZ=0
DO_LANG=0
ACTION=""

ERRORS=0
FREED_KB=0
REMOVED=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] 注意：%s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '[%s] 失败：%s\n' "$(date +%H:%M:%S)" "$*" >&2; ERRORS=$((ERRORS + 1)); }

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    printf '%s [y/N] ' "$1"
    read -r answer || return 1
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# 需要 root 的命令统一走这里；演练模式只打印。
run_root() {
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）sudo $*"
        return 0
    fi
    if [ "$(id -u)" = "0" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run() {
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）$*"
        return 0
    fi
    "$@"
}

human_kb() {
    awk -v kb="$1" 'BEGIN {
        if (kb >= 1048576) printf "%.2f GB", kb / 1048576;
        else if (kb >= 1024) printf "%.1f MB", kb / 1024;
        else printf "%d KB", kb;
    }'
}

# 只删除 allowed_root 之内的路径，防止变量为空或路径越界时误删。
safe_rm() {
    local path="$1" root="$2" kb
    if [ -z "$path" ] || [ -z "$root" ] || [ "$root" = "/" ]; then
        fail "拒绝删除（根目录无效）：$path"
        return 1
    fi
    case "$path" in
        *"/../"*|*"/..") fail "拒绝删除（路径越界）：$path"; return 1 ;;
    esac
    case "$path" in
        "$root"/*) ;;
        *) fail "拒绝删除（路径越界）：$path"; return 1 ;;
    esac
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        return 0
    fi
    kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
    kb="${kb:-0}"
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）删除 $path（$(human_kb "$kb")）"
    else
        if ! rm -rf -- "$path"; then
            fail "删除失败：$path"
            return 1
        fi
    fi
    FREED_KB=$((FREED_KB + kb))
    REMOVED=$((REMOVED + 1))
    return 0
}

backup_file() {
    local src="$1" rel="$2"
    [ -f "$src" ] || return 0
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")" && cp -p "$src" "$BACKUP_DIR/$rel"
}

claude_running() {
    pgrep -x claude >/dev/null 2>&1 && return 0
    pgrep -f '@anthropic-ai/claude-code' >/dev/null 2>&1 && return 0
    return 1
}

chrome_running() {
    if [ "$OS" = "mac" ]; then
        pgrep -x "Google Chrome" >/dev/null 2>&1
    else
        pgrep -x chrome >/dev/null 2>&1
    fi
}

wait_chrome_exit() {
    local i=0
    while chrome_running && [ "$i" -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done
    ! chrome_running
}

# 正常退出 Chrome（等同于菜单里点「退出」，标签页下次可以恢复）。
quit_chrome() {
    if [ "$OS" = "mac" ]; then
        osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1
        wait_chrome_exit && return 0
        pkill -TERM -x "Google Chrome" >/dev/null 2>&1
    else
        pkill -TERM -x chrome >/dev/null 2>&1
    fi
    wait_chrome_exit
}

# ---------------------------------------------------------------- Claude Code

clean_claude() {
    if [ "$DO_CACHE" != "1" ] && [ "$DO_HISTORY" != "1" ]; then
        return 0
    fi
    if [ "$FORCE" != "1" ] && claude_running; then
        fail "Claude Code 正在运行。请先关闭所有 Claude Code 会话和终端（或加 --force）。"
        return 1
    fi

    local before_kb="$FREED_KB" before_n="$REMOVED" item d uid

    if [ "$DO_CACHE" = "1" ]; then
        log "正在清理 Claude Code 缓存、日志和临时文件…"
        for item in cache debug paste-cache image-cache usage-data feedback-bundles \
            feedback/drafts shell-snapshots session-env plans todos statsig logs \
            sessions seed-admin downloads skills/.trash plugins/.trash \
            remote-settings.json policy-limits.json policy-limits.json.stamp.json \
            stats-cache.json; do
            safe_rm "$CLAUDE_DIR/$item" "$CLAUDE_DIR"
        done

        # MCP 日志缓存
        safe_rm "$CLI_CACHE" "$(dirname "$CLI_CACHE")"

        # 临时草稿和粘贴图片
        uid="$(id -u)"
        if [ -n "${TMPDIR:-}" ]; then
            safe_rm "${TMPDIR%/}/claude" "${TMPDIR%/}"
            safe_rm "${TMPDIR%/}/claude-$uid" "${TMPDIR%/}"
        fi
        safe_rm "/tmp/claude" "/tmp"
        safe_rm "/tmp/claude-$uid" "/tmp"

        # npx 缓存里装的 @anthropic-ai/claude-code
        for d in "$HOME"/.npm/_npx/*/node_modules/@anthropic-ai/claude-code; do
            [ -d "$d" ] || continue
            safe_rm "${d%/node_modules/@anthropic-ai/claude-code}" "$HOME/.npm/_npx"
        done
    fi

    if [ "$DO_HISTORY" = "1" ]; then
        log "正在清理 Claude Code 会话历史（删除后无法恢复旧会话）…"
        for item in projects file-history backups tasks history history.jsonl; do
            safe_rm "$CLAUDE_DIR/$item" "$CLAUDE_DIR"
        done
    fi

    log "Claude Code：已清理 $((REMOVED - before_n)) 项，释放 $(human_kb $((FREED_KB - before_kb)))。"
}

# --------------------------------------------------------------------- Chrome

set_chrome_json() {
    # $1 文件  $2 local|prefs
    perl -MJSON::PP -e '
        my ($file, $mode) = @ARGV;
        local $/;
        open(my $in, "<", $file) or die "open: $!";
        my $json = JSON::PP->new->utf8;
        my $data = $json->decode(<$in>);
        close($in);
        $data->{intl} = {} unless ref($data->{intl}) eq "HASH";
        if ($mode eq "local") {
            $data->{intl}{app_locale} = "en-US";
        } else {
            $data->{intl}{accept_languages} = "en-US,en";
            $data->{intl}{selected_languages} = "en-US,en";
        }
        open(my $out, ">", "$file.xc-tmp") or die "write: $!";
        print $out $json->encode($data);
        close($out) or die "close: $!";
        rename("$file.xc-tmp", $file) or die "rename: $!";
    ' "$1" "$2"
}

clean_chrome() {
    [ "$DO_CHROME" = "1" ] || return 0
    if [ ! -d "$CHROME_DATA" ]; then
        warn "未检测到 Google Chrome 用户数据，已跳过。"
        return 0
    fi
    if chrome_running; then
        if [ "$DRY_RUN" = "1" ]; then
            warn "Chrome 正在运行；正式执行时会先询问是否帮你退出 Chrome。"
        elif confirm "Chrome 正在运行，要先退出才能清理和改语言。现在帮你退出 Chrome 吗？" && quit_chrome; then
            log "Chrome 已退出。"
        else
            warn "Chrome 还在运行，已跳过缓存和语言修改；请完全退出 Chrome 后重试。"
            return 0
        fi
    fi

    local before_kb="$FREED_KB" before_n="$REMOVED" profiles=0 profile name sub
    local lang_ok=1
    log "正在清理 Chrome 缓存并设置 en-US…"

    safe_rm "$CHROME_DATA/ShaderCache" "$CHROME_DATA"
    safe_rm "$CHROME_DATA/GrShaderCache" "$CHROME_DATA"

    for profile in "$CHROME_DATA/Default" "$CHROME_DATA"/Profile\ *; do
        [ -d "$profile" ] || continue
        profiles=$((profiles + 1))
        name="$(basename "$profile")"
        for sub in "Cache" "Code Cache" "GPUCache" "DawnGraphiteCache" "DawnWebGPUCache" \
            "Service Worker/CacheStorage" "Service Worker/ScriptCache" "Media Cache"; do
            safe_rm "$profile/$sub" "$CHROME_DATA"
            # macOS / Linux 的磁盘缓存主要放在单独的缓存目录下。
            if [ -d "$CHROME_CACHE/$name" ]; then
                safe_rm "$CHROME_CACHE/$name/$sub" "$CHROME_CACHE"
            fi
        done
        if [ -f "$profile/Preferences" ]; then
            backup_file "$profile/Preferences" "chrome-files/$name/Preferences"
            if [ "$DRY_RUN" = "1" ]; then
                log "（演练）$name/Preferences 的 Accept-Language 设为 en-US,en"
            elif ! set_chrome_json "$profile/Preferences" prefs; then
                fail "$name Preferences 修改失败。"
                lang_ok=0
            fi
        fi
    done

    if [ "$profiles" = "0" ]; then
        warn "Chrome 用户目录中没有找到 Profile。"
    fi

    if [ -f "$CHROME_DATA/Local State" ]; then
        backup_file "$CHROME_DATA/Local State" "chrome-files/Local State"
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）Local State 的界面语言设为 en-US"
        elif ! set_chrome_json "$CHROME_DATA/Local State" local; then
            fail "Local State 修改失败。"
            lang_ok=0
        fi
    fi

    # macOS 上 Chrome 的界面语言跟随「应用语言」设置，单独写一份。
    if [ "$OS" = "mac" ]; then
        run defaults write com.google.Chrome AppleLanguages -array en-US || lang_ok=0
    fi

    if [ "$lang_ok" = "1" ]; then
        log "Chrome：清理 $((REMOVED - before_n)) 个缓存目录，释放 $(human_kb $((FREED_KB - before_kb)))；语言已设为 en-US。"
    else
        log "Chrome：清理 $((REMOVED - before_n)) 个缓存目录，释放 $(human_kb $((FREED_KB - before_kb)))；语言未完全修改。"
    fi
    [ "$DRY_RUN" = "1" ] || [ ! -d "$BACKUP_DIR/chrome-files" ] || log "Chrome 备份：$BACKUP_DIR/chrome-files"
}

# ------------------------------------------------------------ 时区 / 语言

current_tz() {
    if [ "$OS" = "mac" ]; then
        readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'
    elif command -v timedatectl >/dev/null 2>&1; then
        timedatectl show -p Timezone --value 2>/dev/null
    else
        readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'
    fi
}

# macOS「自动设置时区」开关：1 开，0 关，空表示读不到。
auto_tz() {
    defaults read /Library/Preferences/com.apple.timezone.auto Active 2>/dev/null
}

# 时区已经达标（mac 上还要求「自动设置时区」是关的）。
tz_ok() {
    [ "$(current_tz)" = "$TARGET_TZ" ] || return 1
    if [ "$OS" = "mac" ] && [ "$(auto_tz)" = "1" ]; then
        return 1
    fi
    return 0
}

# 系统当前配置的语言（不是当前终端的 LANG）。
current_lang() {
    local f v=""
    if [ "$OS" = "mac" ]; then
        defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ",'
        return 0
    fi
    for f in /etc/default/locale /etc/locale.conf; do
        [ -r "$f" ] || continue
        v="$(sed -n 's/^LANG=//p' "$f" | tr -d '"' | tail -n 1)"
        [ -n "$v" ] && break
    done
    echo "${v:-${LANG:-}}"
}

# Chrome 界面语言（Local State 里的 intl.app_locale），没设置过则输出空。
chrome_lang() {
    [ -f "$CHROME_DATA/Local State" ] || return 0
    perl -MJSON::PP -e '
        local $/;
        open(my $in, "<", $ARGV[0]) or exit 0;
        my $d = eval { JSON::PP->new->utf8->decode(<$in>) };
        exit 0 unless ref($d) eq "HASH" && ref($d->{intl}) eq "HASH";
        print $d->{intl}{app_locale} if defined $d->{intl}{app_locale};
    ' "$CHROME_DATA/Local State" 2>/dev/null
}

snapshot_settings() {
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$BACKUP_DIR" || return 0
    {
        echo "time=$(date)"
        echo "timezone=$(current_tz)"
        if [ "$OS" = "mac" ]; then
            echo "AppleLanguages=$(defaults read -g AppleLanguages 2>/dev/null | tr -d '\n')"
            echo "AppleLocale=$(defaults read -g AppleLocale 2>/dev/null)"
            echo "auto_timezone=$(defaults read /Library/Preferences/com.apple.timezone.auto Active 2>/dev/null)"
            echo "--- input sources"
            defaults read com.apple.HIToolbox AppleEnabledInputSources 2>/dev/null
        else
            echo "--- locale"
            locale 2>/dev/null
            echo "--- /etc/default/locale"
            cat /etc/default/locale 2>/dev/null
            echo "--- /etc/locale.conf"
            cat /etc/locale.conf 2>/dev/null
            echo "--- keyboard"
            localectl status 2>/dev/null
            gsettings get org.gnome.desktop.input-sources sources 2>/dev/null
            gsettings get org.freedesktop.ibus.general preload-engines 2>/dev/null
        fi
    } > "$BACKUP_DIR/settings-snapshot.txt"
    log "设置备份：$BACKUP_DIR/settings-snapshot.txt"
}

set_timezone() {
    [ "$DO_TZ" = "1" ] || return 0
    log "当前时区 $(current_tz)，准备设置…"
    local out="" zone=""
    if [ "$OS" = "mac" ]; then
        # 先关掉「自动设置时区」，否则会被定位改回去。
        run_root defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false \
            || log "警告：关闭「自动设置时区」失败，时区之后可能被系统改回去。"
        if [ "$DRY_RUN" = "1" ]; then
            run_root systemsetup -settimezone "$TARGET_TZ"
        else
            # systemsetup 失败时也经常返回 0，所以不看返回值，只看时区实际有没有变。
            out="$(run_root systemsetup -settimezone "$TARGET_TZ" 2>&1)"
            if [ "$(current_tz)" != "$TARGET_TZ" ]; then
                # systemsetup 在部分系统上被限制，退回直接改链接。
                zone="/var/db/timezone/zoneinfo/$TARGET_TZ"
                [ -e "$zone" ] || zone="/usr/share/zoneinfo/$TARGET_TZ"
                run_root ln -sf "$zone" /etc/localtime
            fi
        fi
    elif command -v timedatectl >/dev/null 2>&1; then
        if ! run_root timedatectl set-timezone "$TARGET_TZ"; then
            fail "时区设置失败。"
            return 1
        fi
    else
        if ! run_root ln -sf "/usr/share/zoneinfo/$TARGET_TZ" /etc/localtime; then
            fail "时区设置失败。"
            return 1
        fi
        [ -f /etc/timezone ] && run_root sh -c "echo $TARGET_TZ > /etc/timezone"
    fi
    [ "$DRY_RUN" = "1" ] && return 0
    # 以实际结果为准，不能只看命令有没有报错。
    if [ "$(current_tz)" != "$TARGET_TZ" ]; then
        fail "时区设置失败：当前仍是 $(current_tz)。"
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        if [ "$OS" = "mac" ]; then
            warn "可以手动改：系统设置 > 通用 > 日期与时间，关掉「自动设置时区」，再选洛杉矶。"
        fi
        return 1
    fi
    if [ "$OS" = "mac" ] && [ "$(auto_tz)" = "1" ]; then
        warn "「自动设置时区」没有关掉，时区之后可能被改回去；请到 系统设置 > 通用 > 日期与时间 手动关闭。"
    fi
    log "时区已设为 $TARGET_TZ，现在是 $(date '+%Y-%m-%d %H:%M %Z')。"
}

set_language_mac() {
    run defaults write -g AppleLanguages -array en-US || return 1
    run defaults write -g AppleLocale -string en_US || return 1
    return 0
}

set_language_linux() {
    if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf-\{0,1\}8$'; then
        if command -v locale-gen >/dev/null 2>&1; then
            run_root locale-gen en_US.UTF-8 || return 1
        elif command -v localedef >/dev/null 2>&1; then
            run_root localedef -i en_US -f UTF-8 en_US.UTF-8 || return 1
        else
            fail "系统里没有 en_US.UTF-8，也找不到 locale-gen。"
            return 1
        fi
    fi
    # 只给 LANG / LANGUAGE，其余 LC_* 会被清掉，从而一起跟随英文。
    if command -v localectl >/dev/null 2>&1; then
        run_root localectl set-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en || return 1
    elif command -v update-locale >/dev/null 2>&1; then
        run_root update-locale --reset LANG=en_US.UTF-8 LANGUAGE=en_US:en || return 1
    else
        fail "找不到 localectl 或 update-locale。"
        return 1
    fi
    # 桌面环境按用户记语言，尽量一起改；失败不算错。
    if command -v busctl >/dev/null 2>&1; then
        run busctl call org.freedesktop.Accounts "/org/freedesktop/Accounts/User$(id -u)" \
            org.freedesktop.Accounts.User SetLanguage s en_US.UTF-8 >/dev/null 2>&1
        run busctl call org.freedesktop.Accounts "/org/freedesktop/Accounts/User$(id -u)" \
            org.freedesktop.Accounts.User SetFormatsLocale s en_US.UTF-8 >/dev/null 2>&1
    fi
    if command -v gsettings >/dev/null 2>&1; then
        run gsettings set org.gnome.system.locale region en_US.UTF-8 >/dev/null 2>&1
    fi
    return 0
}

# 和 Windows 版一样：清空键盘布局 / 输入法列表，只留美式键盘。
set_keyboard_mac() {
    local plist="$HOME/Library/Preferences/com.apple.HIToolbox.plist"
    local us='<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout ID</key><integer>0</integer><key>KeyboardLayout Name</key><string>U.S.</string></dict>'
    backup_file "$plist" "keyboard/com.apple.HIToolbox.plist"
    run defaults write com.apple.HIToolbox AppleEnabledInputSources -array "$us" || return 1
    run defaults write com.apple.HIToolbox AppleSelectedInputSources -array "$us" || return 1
    run defaults write com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID -string com.apple.keylayout.US || return 1
    run defaults delete com.apple.HIToolbox AppleInputSourceHistory >/dev/null 2>&1
    return 0
}

set_keyboard_linux() {
    local fcitx="${XDG_CONFIG_HOME:-$HOME/.config}/fcitx5/profile"
    # 系统级键盘布局
    if command -v localectl >/dev/null 2>&1; then
        run_root localectl set-x11-keymap us || return 1
    fi
    # GNOME 输入源和 ibus；没有对应桌面时失败不算错。
    if command -v gsettings >/dev/null 2>&1; then
        run gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]" >/dev/null 2>&1
        run gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'us')]" >/dev/null 2>&1
        run gsettings set org.freedesktop.ibus.general preload-engines "['xkb:us::eng']" >/dev/null 2>&1
    fi
    # fcitx5：把输入法分组改成只有美式键盘。
    if [ -f "$fcitx" ]; then
        backup_file "$fcitx" "keyboard/fcitx5-profile"
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）fcitx5 输入法列表改为只有 keyboard-us"
        else
            printf '%s\n' '[Groups/0]' 'Name=Default' 'Default Layout=us' 'DefaultIM=keyboard-us' '' \
                '[Groups/0/Items/0]' 'Name=keyboard-us' 'Layout=' '' '[GroupOrder]' '0=Default' > "$fcitx" || return 1
        fi
    fi
    return 0
}

set_language() {
    [ "$DO_LANG" = "1" ] || return 0
    log "准备把系统语言 / 区域设为 en-US…"
    if [ "$OS" = "mac" ]; then
        set_language_mac || { fail "语言设置失败。"; return 1; }
        set_keyboard_mac || { fail "键盘布局设置失败。"; return 1; }
    else
        set_language_linux || { fail "语言设置失败。"; return 1; }
        set_keyboard_linux || { fail "键盘布局设置失败。"; return 1; }
    fi
    log "语言 / 区域已设为 en-US，键盘布局只保留美式键盘；注销或重启后生效。"
}

# ------------------------------------------------------- 安装 / 卸载 Claude

install_code() {
    confirm "将用官方脚本安装 Claude Code，是否继续？" || { log "已取消。"; return 0; }
    if ! command -v curl >/dev/null 2>&1; then
        fail "需要 curl。"
        return 1
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）curl -fsSL https://claude.ai/install.sh | bash"
        return 0
    fi
    if curl -fsSL https://claude.ai/install.sh | bash; then
        log "Claude Code 安装完成。"
    else
        fail "Claude Code 安装失败。"
    fi
}

uninstall_code() {
    local msg="将卸载 Claude Code，但保留 $CLAUDE_DIR 配置和会话数据。确定继续？"
    if [ "$REMOVE_DATA" = "1" ]; then
        msg="将卸载 Claude Code，并删除 $CLAUDE_DIR 配置和会话数据。此操作不可恢复，确定继续？"
    fi
    confirm "$msg" || { log "已取消。"; return 0; }
    if [ "$FORCE" != "1" ] && claude_running; then
        fail "Claude Code 正在运行。请先关闭所有 Claude Code 会话和终端（或加 --force）。"
        return 1
    fi

    if command -v brew >/dev/null 2>&1 && brew list --cask claude-code >/dev/null 2>&1; then
        run brew uninstall --cask claude-code || fail "brew 卸载失败。"
    fi
    if command -v npm >/dev/null 2>&1 && npm ls -g @anthropic-ai/claude-code >/dev/null 2>&1; then
        run npm uninstall -g @anthropic-ai/claude-code || fail "npm 卸载失败。"
    fi
    # 原生安装
    safe_rm "$HOME/.local/bin/claude" "$HOME/.local/bin"
    safe_rm "$HOME/.local/share/claude" "$HOME/.local/share"

    if [ "$REMOVE_DATA" = "1" ]; then
        safe_rm "$CLAUDE_DIR" "$(dirname "$CLAUDE_DIR")"
        safe_rm "$CLAUDE_JSON" "$(dirname "$CLAUDE_JSON")"
        log "Claude Code 已卸载。用户数据已删除。"
    else
        log "Claude Code 已卸载。配置和会话数据已保留。"
    fi
}

install_desktop() {
    if [ "$OS" != "mac" ]; then
        warn "Claude Desktop 没有通用的 Linux 安装方式，已跳过。"
        return 0
    fi
    if ! command -v brew >/dev/null 2>&1; then
        warn "未找到 Homebrew。请到 https://claude.ai/download 下载安装包。"
        return 0
    fi
    confirm "将用 Homebrew 安装 Claude Desktop，是否继续？" || { log "已取消。"; return 0; }
    if run brew install --cask claude; then
        log "Claude Desktop 安装完成。"
    else
        fail "Claude Desktop 安装失败。"
    fi
}

uninstall_desktop() {
    if [ "$OS" != "mac" ]; then
        warn "Linux 上没有 Claude Desktop 可卸载，已跳过。"
        return 0
    fi
    confirm "将卸载 Claude Desktop。聊天记录和项目文件不会被删除。确定继续？" || { log "已取消。"; return 0; }
    if command -v brew >/dev/null 2>&1 && brew list --cask claude >/dev/null 2>&1; then
        run brew uninstall --cask claude || fail "brew 卸载失败。"
    elif [ -d "/Applications/Claude.app" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）删除 /Applications/Claude.app"
        else
            rm -rf "/Applications/Claude.app" 2>/dev/null || run_root rm -rf "/Applications/Claude.app" \
                || fail "删除 /Applications/Claude.app 失败。"
        fi
    else
        warn "未检测到 Claude Desktop。"
        return 0
    fi
    log "Claude Desktop 已卸载。"
}

# ----------------------------------------------------------------- 主流程

# 逐项显示当前状态，✓ 表示已经符合目标，✗ 表示还需要处理。
status() {
    local code="未安装" desktop="未安装" tz lang cl t_ok="✗" l_ok="✗" c_ok="✗" auto=""
    command -v claude >/dev/null 2>&1 && code="已安装"
    [ -x "$HOME/.local/bin/claude" ] && code="已安装"
    [ "$OS" = "mac" ] && [ -d "/Applications/Claude.app" ] && desktop="已安装"
    [ "$OS" = "linux" ] && desktop="不适用"

    tz="$(current_tz)"
    lang="$(current_lang)"
    [ "$tz" = "$TARGET_TZ" ] && t_ok="✓"
    if [ "$OS" = "mac" ] && [ "$(auto_tz)" = "1" ]; then
        auto="；「自动设置时区」开着，会被改回去"
        t_ok="✗"
    fi
    case "$lang" in en-US*|en_US*) l_ok="✓" ;; esac

    echo "  $t_ok 时区：${tz:-未知}（目标 $TARGET_TZ$auto）"
    echo "  $l_ok 系统语言：${lang:-未知}（目标 en-US）"
    if [ -f "$CHROME_DATA/Local State" ]; then
        cl="$(chrome_lang)"
        [ "$cl" = "en-US" ] && c_ok="✓"
        echo "  $c_ok Chrome 语言：${cl:-未设置，跟随系统}（目标 en-US）"
    else
        echo "  - Chrome：未检测到"
    fi
    echo "  - Claude Code：$code    Claude Desktop：$desktop"
    echo "  - Claude 数据目录：$CLAUDE_DIR"
}

run_pipeline() {
    if [ "$DO_CACHE$DO_HISTORY$DO_CHROME$DO_TZ$DO_LANG" = "00000" ]; then
        echo "请至少选择一个执行项目。"
        return 1
    fi
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$DATA_DIR/backups/$STAMP"
    local need_root=0 want_lang="$DO_LANG"

    [ "$DRY_RUN" = "1" ] && log "演练模式：只显示将要做的事，不做任何修改。"
    if [ "$DO_HISTORY" = "1" ]; then
        confirm "会删除 Claude Code 的会话记录、自动记忆和提示词历史，无法恢复。确定继续？" || DO_HISTORY=0
    fi
    if [ "$DO_TZ" = "1" ] && [ "$DRY_RUN" != "1" ] && tz_ok; then
        log "时区已经是 $TARGET_TZ，无需修改。"
        DO_TZ=0
    fi

    if [ "$DO_TZ" = "1" ] || [ "$DO_LANG" = "1" ]; then
        # mac 的语言 / 键盘是用户级设置，不需要 root；时区、Linux 的语言需要。
        [ "$DO_TZ" = "1" ] && need_root=1
        [ "$DO_LANG" = "1" ] && [ "$OS" != "mac" ] && need_root=1
        # 先一次性拿到管理员权限，拿不到就明说，不要等到后面静默失败。
        if [ "$need_root" = "1" ] && [ "$DRY_RUN" != "1" ] && [ "$(id -u)" != "0" ]; then
            log "修改时区 / 语言需要管理员权限，请输入本机登录密码（输入时屏幕上不显示，输完按回车）。"
            if ! command -v sudo >/dev/null 2>&1 || ! sudo -v; then
                fail "没有拿到管理员权限（密码不对，或当前账户不是管理员），已跳过需要管理员权限的项目。"
                DO_TZ=0
                [ "$OS" = "mac" ] || DO_LANG=0
            fi
        fi
        if [ "$DO_TZ" = "1" ] || [ "$DO_LANG" = "1" ]; then
            snapshot_settings
        fi
    fi

    # 先做需要管理员权限的两项，免得清理耗时太久导致 sudo 授权过期。
    set_timezone
    set_language
    clean_claude
    clean_chrome

    if [ "$ERRORS" = "0" ]; then
        log "执行完成。共释放 $(human_kb "$FREED_KB")。"
    else
        log "执行结束，有 $ERRORS 个错误，请看上面标了「失败」的行。"
    fi
    if [ "$DRY_RUN" != "1" ]; then
        echo
        echo "当前状态："
        status
    fi
    if [ "$want_lang" = "1" ] && [ "$DO_LANG" = "1" ] && [ "$DRY_RUN" != "1" ]; then
        echo
        log "提示：语言和键盘设置需要注销或重启电脑后才完全生效。"
    fi
    [ "$ERRORS" = "0" ]
}

menu() {
    local c picked act choices
    while :; do
        DO_CACHE=0; DO_HISTORY=0; DO_CHROME=0; DO_TZ=0; DO_LANG=0
        REMOVE_DATA=0; ERRORS=0; FREED_KB=0; REMOVED=0
        picked=0; act=""

        echo
        echo "================ 小川环境助手 $VERSION（$OS）================"
        status
        echo
        echo "  1) 清理 Claude Code 缓存、日志、临时文件"
        echo "  2) 清理 Claude Code 会话历史（不可恢复）"
        echo "  3) 清理 Chrome 缓存，并把 Chrome 语言设为 en-US"
        echo "  4) 时区改为 $TARGET_TZ"
        echo "  5) 系统语言 / 区域改为 en-US，键盘布局只留美式键盘"
        echo "  a) 一键执行 1 3 4 5（推荐）"
        echo "  i) 安装 Claude Code        u) 卸载 Claude Code"
        echo "  I) 安装 Claude Desktop     U) 卸载 Claude Desktop"
        echo "  q) 退出"
        echo
        printf '请输入要执行的项目（可多选，用空格分开，例如 1 3 4），然后按回车：'
        read -r choices || exit 0

        # 允许用逗号分隔；关掉通配符展开，免得输入 * 之类被当成文件名。
        set -f
        # shellcheck disable=SC2086
        set -- $(printf '%s' "$choices" | tr ',' ' ')
        set +f
        for c in "$@"; do
            case "$c" in
                1) DO_CACHE=1; picked=1 ;;
                2) DO_HISTORY=1; picked=1 ;;
                3) DO_CHROME=1; picked=1 ;;
                4) DO_TZ=1; picked=1 ;;
                5) DO_LANG=1; picked=1 ;;
                a|A) DO_CACHE=1; DO_CHROME=1; DO_TZ=1; DO_LANG=1; picked=1 ;;
                i) act="install_code" ;;
                u) act="uninstall_code" ;;
                I) act="install_desktop" ;;
                U) act="uninstall_desktop" ;;
                q|Q) exit 0 ;;
                *) echo "看不懂的选项：$c"; act="none"; break ;;
            esac
        done

        case "$act" in
            none) ;;
            uninstall_code)
                if confirm "同时删除配置和会话数据？"; then REMOVE_DATA=1; fi
                uninstall_code ;;
            install_code|install_desktop|uninstall_desktop) "$act" ;;
            "")
                if [ "$picked" = "1" ]; then
                    run_pipeline
                else
                    continue
                fi ;;
        esac

        echo
        printf '按回车返回菜单（输入 q 退出）：'
        read -r c || exit 0
        case "$c" in q|Q) exit 0 ;; esac
    done
}

usage() {
    cat <<EOF
小川环境助手 $VERSION（macOS / Linux）

用法：
  bash $0                  交互菜单（不带参数）
  bash $0 [选项]           按选项直接执行
  bash $0 status           检查当前状态（时区 / 语言 / Chrome 是否已达标）
  bash $0 install-code     安装 Claude Code
  bash $0 uninstall-code [--remove-data]
  bash $0 install-desktop  安装 Claude Desktop（仅 macOS）
  bash $0 uninstall-desktop

选项：
  --cache        清理 Claude Code 缓存、日志、临时文件
  --history      清理 Claude Code 会话历史（不可恢复）
  --chrome       清理 Chrome 缓存，并把 Chrome 语言设为 en-US
  --timezone     时区改为 $TARGET_TZ
  --language     系统语言 / 区域改为 en-US，并清空键盘布局只留美式键盘
  --all          等于 --cache --chrome --timezone --language（不含 --history）
  --dry-run      演练：只显示将要做的事，不做任何修改
  --force        Claude Code 在运行时也继续清理
  -y, --yes      不再逐项确认（Chrome 在运行时会直接帮你退出）
  -h, --help     显示本说明

不要在前面加 sudo：脚本会在需要时自己申请管理员权限，只要输一次密码。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cache) DO_CACHE=1 ;;
        --history) DO_HISTORY=1 ;;
        --chrome) DO_CHROME=1 ;;
        --timezone) DO_TZ=1 ;;
        --language) DO_LANG=1 ;;
        --all) DO_CACHE=1; DO_CHROME=1; DO_TZ=1; DO_LANG=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        --remove-data) REMOVE_DATA=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        install-code|uninstall-code|install-desktop|uninstall-desktop|status) ACTION="$1" ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

case "$ACTION" in
    install-code) install_code ;;
    uninstall-code) uninstall_code ;;
    install-desktop) install_desktop ;;
    uninstall-desktop) uninstall_desktop ;;
    status) echo "小川环境助手 $VERSION（$OS）"; status ;;
    "")
        if [ "$DO_CACHE$DO_HISTORY$DO_CHROME$DO_TZ$DO_LANG" != "00000" ]; then
            run_pipeline
        elif [ -t 0 ]; then
            menu
        else
            usage
            exit 2
        fi
        ;;
esac
