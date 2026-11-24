#!/usr/bin/env bash
# 小川环境还原助手 · macOS / Linux 版
# 把 xiaochuan-env.sh 改过的设置还原成「中国 / 中文」：
#   时区改回 Asia/Shanghai、系统语言 / 区域改回简体中文并加回中文输入法、
#   打开系统定位、打开系统 IPv6、Chrome 语言改回 zh-CN 并恢复 Chrome 定位。
# 清理掉的缓存 / 会话历史无法还原，也不需要还原。
# 兼容 macOS 自带的 bash 3.2：不使用关联数组、mapfile、${var,,} 等新语法。

VERSION="1.0.0"
TARGET_TZ="Asia/Shanghai"
TARGET_LOCALE="zh_CN.UTF-8"

case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux) OS="linux" ;;
    *) echo "只支持 macOS 和 Linux。" >&2; exit 1 ;;
esac

# 用 sudo 整个运行会把语言、键盘这些「用户级」操作做到 root 账户上，
# 所以这里退回原用户身份重新执行，需要管理员权限的步骤由脚本自己逐条 sudo。
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -f "$0" ]; then
    echo "检测到用 sudo 运行：改回用户 $SUDO_USER 的身份执行，需要管理员权限的步骤会自动提权。"
    exec sudo -u "$SUDO_USER" -H -- bash "$0" "$@"
fi

DATA_DIR="$HOME/.xiaochuan-env"
# xiaochuan-env.sh 修改前留下的备份；最早的那一份就是最原始的设置。
ENV_BACKUPS="$DATA_DIR/backups"
# 本脚本修改前的备份单独放，不和上面的混在一起。
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$DATA_DIR/restore-backups/$STAMP"

if [ "$OS" = "mac" ]; then
    CHROME_DATA="$HOME/Library/Application Support/Google/Chrome"
else
    CHROME_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome"
fi

DRY_RUN=0
ASSUME_YES=0
DO_CHROME=0
DO_TZ=0
DO_LANG=0
DO_LOC=0
DO_IP6=0
ACTION=""
IP6_SYSCTL_FILE="/etc/sysctl.d/99-xiaochuan-disable-ipv6.conf"

ERRORS=0
NO_ROOT=0
STATUS_BAD=0

# ---------------------------------------------------------------- 结果汇总
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_OK_BAR=$'\033[1;97;42m'; C_BAD_BAR=$'\033[1;97;41m'
    C_DIM_BAR=$'\033[1;30;47m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_BAD=""; C_OK_BAR=""; C_BAD_BAR=""; C_DIM_BAR=""; C_OFF=""
fi
RESULTS=""      # 每行一条：种类<TAB>文字，种类是 ok / bad / info
OK_COUNT=0
BAD_COUNT=0
ok_item() { RESULTS="${RESULTS}ok	$1
"; OK_COUNT=$((OK_COUNT + 1)); }
bad_item() { RESULTS="${RESULTS}bad	$1
"; BAD_COUNT=$((BAD_COUNT + 1)); }
info_item() { RESULTS="${RESULTS}info	$1
"; }

print_result() {
    local kind text
    echo
    echo "================ 执行结果 ================"
    while IFS='	' read -r kind text; do
        case "$kind" in
            ok) printf '  %s✓ %s%s\n' "$C_OK" "$text" "$C_OFF" ;;
            bad) printf '  %s✗ 没有完成：%s%s\n' "$C_BAD" "$text" "$C_OFF" ;;
            info) printf '  - %s\n' "$text" ;;
        esac
    done <<RESULT_EOF
$RESULTS
RESULT_EOF
    echo "=========================================="
    if [ "$BAD_COUNT" != "0" ]; then
        printf '%s 结果：有 %s 行没有完成（上面标 ✗ 的红色行） %s\n' "$C_BAD_BAR" "$BAD_COUNT" "$C_OFF"
    elif [ "$OK_COUNT" != "0" ]; then
        printf '%s 结果：全部完成 %s\n' "$C_OK_BAR" "$C_OFF"
    else
        printf '%s 结果：没有做任何修改 %s\n' "$C_DIM_BAR" "$C_OFF"
    fi
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] 注意：%s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '%s[%s] 失败：%s%s\n' "$C_BAD" "$(date +%H:%M:%S)" "$*" "$C_OFF" >&2; ERRORS=$((ERRORS + 1)); bad_item "$*"; }
skip() { log "$*"; info_item "$*"; }

# 需要 root 的命令统一走这里；演练模式只打印。
run_root() {
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）sudo $*"
        return 0
    fi
    if [ "$(id -u)" = "0" ]; then
        "$@"
    elif [ "$NO_ROOT" = "1" ]; then
        return 1
    else
        sudo "$@"
    fi
}

have_root() {
    [ "$(id -u)" = "0" ] && return 0
    [ "$NO_ROOT" = "1" ] && return 1
    sudo -n true >/dev/null 2>&1
}

run() {
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）$*"
        return 0
    fi
    "$@"
}

backup_file() {
    local src="$1" rel="$2"
    [ -f "$src" ] || return 0
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")" && cp -p "$src" "$BACKUP_DIR/$rel"
}

# xiaochuan-env.sh 最早一次备份里的某个文件（$1 是备份目录里的相对路径）；没有则输出空。
# 备份目录名是时间，按名字排序的第一个就是最早的。
oldest_backup() {
    local d
    for d in "$ENV_BACKUPS"/*/; do
        if [ -f "$d$1" ]; then
            printf '%s' "$d$1"
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------------- Chrome

chrome_running() {
    if [ "$OS" = "mac" ]; then
        pgrep -x "Google Chrome" >/dev/null 2>&1 && return 0
        pgrep -f "Google Chrome.app/Contents/" >/dev/null 2>&1
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

# 关闭 Chrome：先正常退出（标签页下次可以恢复），退不掉再强制结束。
quit_chrome() {
    if [ "$OS" = "mac" ]; then
        osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1
        wait_chrome_exit && return 0
        pkill -TERM -x "Google Chrome" >/dev/null 2>&1
    else
        pkill -TERM -x chrome >/dev/null 2>&1
    fi
    wait_chrome_exit && return 0
    if [ "$OS" = "mac" ]; then
        pkill -KILL -x "Google Chrome" >/dev/null 2>&1
        pkill -KILL -f "Google Chrome.app/Contents/" >/dev/null 2>&1
    else
        pkill -KILL -x chrome >/dev/null 2>&1
    fi
    wait_chrome_exit
}

# 个人资料的配置里，定位的默认值是不是还被设成「禁止」（2）。$1 文件
chrome_geo_off() {
    grep -q '"default_content_setting_values" *: *{[^{}]*"geolocation" *: *2' "$1" 2>/dev/null
}

# 核对 Chrome 配置文件是否已经还原。$1 文件  $2 local|prefs
chrome_json_ok() {
    if [ "$2" = "local" ]; then
        grep -q '"app_locale" *: *"zh-CN"' "$1" 2>/dev/null
    else
        grep -q '"accept_languages" *: *"zh-CN,zh"' "$1" 2>/dev/null && ! chrome_geo_off "$1"
    fi
}

# 定位还被禁止的 Chrome 个人资料（目录名，用顿号隔开）；都恢复了则输出空。
chrome_geo_off_profiles() {
    local profile out=""
    for profile in "$CHROME_DATA/Default" "$CHROME_DATA"/Profile\ *; do
        [ -f "$profile/Preferences" ] || continue
        chrome_geo_off "$profile/Preferences" && out="${out:+$out、}$(basename "$profile")"
    done
    printf '%s' "$out"
}

set_chrome_json_perl() {
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
            $data->{intl}{app_locale} = "zh-CN";
        } else {
            # 语言列表改回中文；「不翻译的语言」、翻译目标语言也改回中文。
            $data->{intl}{accept_languages} = "zh-CN,zh";
            $data->{intl}{selected_languages} = "zh-CN,zh";
            $data->{translate_blocked_languages} = ["zh-CN"];
            $data->{translate_recent_target} = "zh-CN";
            # 定位：去掉「禁止」，回到 Chrome 默认的「网站可以询问」。
            my $prof = $data->{profile};
            if (ref($prof) eq "HASH" && ref($prof->{default_content_setting_values}) eq "HASH") {
                delete $prof->{default_content_setting_values}{geolocation};
            }
        }
        open(my $out, ">", "$file.xc-tmp") or die "write: $!";
        print $out $json->encode($data);
        close($out) or die "close: $!";
        rename("$file.xc-tmp", $file) or die "rename: $!";
    ' "$1" "$2"
}

set_chrome_json_python() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" "$2" <<'PY'
import json, os, sys
path, mode = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
intl = data.get("intl")
if not isinstance(intl, dict):
    intl = data["intl"] = {}
if mode == "local":
    intl["app_locale"] = "zh-CN"
else:
    intl["accept_languages"] = "zh-CN,zh"
    intl["selected_languages"] = "zh-CN,zh"
    data["translate_blocked_languages"] = ["zh-CN"]
    data["translate_recent_target"] = "zh-CN"
    prof = data.get("profile")
    if isinstance(prof, dict) and isinstance(prof.get("default_content_setting_values"), dict):
        prof["default_content_setting_values"].pop("geolocation", None)
tmp = path + ".xc-tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, separators=(",", ":"))
os.replace(tmp, path)
PY
}

# perl 不行换 python3，再不行就用管理员权限把文件属主改回来重试；每次都读回文件核对。
set_chrome_json() {
    set_chrome_json_perl "$1" "$2" 2>/dev/null && chrome_json_ok "$1" "$2" && return 0
    set_chrome_json_python "$1" "$2" 2>/dev/null && chrome_json_ok "$1" "$2" && return 0
    if have_root; then
        run_root chown "$(id -u):$(id -g)" "$1" "$(dirname "$1")" >/dev/null 2>&1
        set_chrome_json_perl "$1" "$2" 2>/dev/null && chrome_json_ok "$1" "$2" && return 0
        set_chrome_json_python "$1" "$2" 2>/dev/null && chrome_json_ok "$1" "$2" && return 0
    fi
    return 1
}

# Chrome 界面语言（Local State 里的 intl.app_locale），没设置过则输出空。
chrome_lang() {
    [ -f "$CHROME_DATA/Local State" ] || return 0
    sed -n 's/.*"app_locale" *: *"\([^"]*\)".*/\1/p' "$CHROME_DATA/Local State" 2>/dev/null | head -n 1
}

restore_chrome() {
    [ "$DO_CHROME" = "1" ] || return 0
    if [ ! -d "$CHROME_DATA" ]; then
        warn "未检测到 Google Chrome 用户数据，已跳过。"
        return 0
    fi
    if chrome_running; then
        if [ "$DRY_RUN" = "1" ]; then
            warn "Chrome 正在运行；正式执行时会先把 Chrome 关闭。"
        elif log "Chrome 正在运行，先把它关闭…" && quit_chrome; then
            log "Chrome 已关闭。"
        else
            fail "Chrome 关不掉，已跳过语言和定位的还原；请手动完全退出 Chrome 后重试。"
            return 0
        fi
    fi

    local profile name all_ok=1
    log "正在把 Chrome 语言改回 zh-CN，并恢复 Chrome 定位…"
    for profile in "$CHROME_DATA/Default" "$CHROME_DATA"/Profile\ *; do
        [ -f "$profile/Preferences" ] || continue
        name="$(basename "$profile")"
        backup_file "$profile/Preferences" "chrome-files/$name/Preferences"
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）$name/Preferences 的语言列表改回中文（zh-CN,zh）；定位改回「网站可以询问」"
        elif ! set_chrome_json "$profile/Preferences" prefs; then
            fail "$name Preferences 修改失败。"
            all_ok=0
        fi
    done

    if [ -f "$CHROME_DATA/Local State" ]; then
        backup_file "$CHROME_DATA/Local State" "chrome-files/Local State"
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）Local State 的界面语言改回 zh-CN"
        elif ! set_chrome_json "$CHROME_DATA/Local State" local; then
            fail "Local State 修改失败。"
            all_ok=0
        fi
    fi

    # macOS 上删掉给 Chrome 单独指定的「应用语言」，让它重新跟随系统语言。
    if [ "$OS" = "mac" ]; then
        run defaults delete com.google.Chrome AppleLanguages >/dev/null 2>&1
    fi

    [ "$all_ok" = "1" ] && log "Chrome：语言已改回 zh-CN，定位已恢复为「网站可以询问」。"
    [ "$DRY_RUN" = "1" ] || [ ! -d "$BACKUP_DIR/chrome-files" ] || log "Chrome 备份：$BACKUP_DIR/chrome-files"
}

# ------------------------------------------------------------------- 时区

current_tz() {
    if [ "$OS" = "mac" ]; then
        readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'
    elif command -v timedatectl >/dev/null 2>&1; then
        timedatectl show -p Timezone --value 2>/dev/null
    else
        readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'
    fi
}

tz_zone_file() {
    local d
    for d in /var/db/timezone/zoneinfo /usr/share/zoneinfo; do
        if [ -e "$d/$TARGET_TZ" ]; then
            echo "$d/$TARGET_TZ"
            return 0
        fi
    done
    return 1
}

# 用指定方式改时区。$1：systemsetup | timedatectl | link | relink
tz_apply() {
    local zone
    case "$1" in
        systemsetup)
            run_root systemsetup -settimezone "$TARGET_TZ" ;;
        timedatectl)
            command -v timedatectl >/dev/null 2>&1 || return 1
            run_root timedatectl set-timezone "$TARGET_TZ" ;;
        link)
            zone="$(tz_zone_file)" || { echo "找不到 $TARGET_TZ 的 zoneinfo 文件"; return 1; }
            run_root ln -sf "$zone" /etc/localtime ;;
        relink)
            zone="$(tz_zone_file)" || return 1
            run_root rm -f /etc/localtime && run_root ln -s "$zone" /etc/localtime ;;
    esac
}

set_timezone() {
    [ "$DO_TZ" = "1" ] || return 0
    log "当前时区 $(current_tz)，准备改回 $TARGET_TZ…"
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）依次尝试各种方式把时区改为 $TARGET_TZ，直到核对成功。"
        return 0
    fi
    if [ "$(current_tz)" = "$TARGET_TZ" ]; then
        log "时区已经是 $TARGET_TZ，无需修改。"
        return 0
    fi
    local methods="timedatectl link relink" m out="" n=0
    [ "$OS" = "mac" ] && methods="systemsetup link relink"
    # 一种方式不行就换下一种；命令的返回值不可靠，每次都看时区实际有没有变。
    for m in $methods; do
        [ "$(current_tz)" = "$TARGET_TZ" ] && break
        n=$((n + 1))
        log "时区：尝试第 $n 种方式（$m）…"
        out="$out
[$m] $(tz_apply "$m" 2>&1)"
    done
    if [ "$(current_tz)" != "$TARGET_TZ" ]; then
        fail "时区设置失败：所有方式都试过了，当前仍是 $(current_tz)。各方式的输出：$out"
        return 1
    fi
    if [ "$OS" = "linux" ] && [ -f /etc/timezone ]; then
        run_root sh -c "echo $TARGET_TZ > /etc/timezone"
    fi
    log "时区已设为 $TARGET_TZ，现在是 $(date '+%Y-%m-%d %H:%M %Z')。"
}

# ------------------------------------------------------------ 语言 / 输入法

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

lang_ok() {
    case "$(current_lang)" in
        zh-Hans*|zh-CN*|zh_CN*) return 0 ;;
    esac
    return 1
}

set_language_mac() {
    run defaults write -g AppleLanguages -array zh-Hans-CN en-CN
    run defaults write -g AppleLocale -string zh_CN
    [ "$DRY_RUN" = "1" ] && return 0
    if ! lang_ok; then
        defaults write NSGlobalDomain AppleLanguages -array zh-Hans-CN en-CN
        defaults write NSGlobalDomain AppleLocale -string zh_CN
        killall -u "$(id -un)" cfprefsd >/dev/null 2>&1
        sleep 1
    fi
    # 有管理员权限时把系统级（登录界面、新用户）的语言也改回来；失败不算错。
    if have_root; then
        run_root defaults write /Library/Preferences/.GlobalPreferences AppleLanguages -array zh-Hans-CN en-CN >/dev/null 2>&1
        run_root defaults write /Library/Preferences/.GlobalPreferences AppleLocale -string zh_CN >/dev/null 2>&1
    fi
    lang_ok
}

zh_locale_present() {
    locale -a 2>/dev/null | grep -qi '^zh_CN\.utf-\{0,1\}8$'
}

set_language_linux() {
    local f wrote=0
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）依次尝试 localectl / update-locale / 直接写配置文件，把系统语言改为 $TARGET_LOCALE，直到核对成功。"
        return 0
    fi
    if ! zh_locale_present; then
        if command -v locale-gen >/dev/null 2>&1; then
            run_root locale-gen "$TARGET_LOCALE" >/dev/null 2>&1
        fi
        if ! zh_locale_present && command -v localedef >/dev/null 2>&1; then
            run_root localedef -i zh_CN -f UTF-8 "$TARGET_LOCALE" >/dev/null 2>&1
        fi
        zh_locale_present || warn "系统里还没有 $TARGET_LOCALE 这个 locale，语言可能不完全生效。"
    fi
    if command -v localectl >/dev/null 2>&1; then
        log "语言：尝试 localectl…"
        run_root localectl set-locale "LANG=$TARGET_LOCALE" LANGUAGE=zh_CN:zh >/dev/null 2>&1
    fi
    if ! lang_ok && command -v update-locale >/dev/null 2>&1; then
        log "语言：尝试 update-locale…"
        run_root update-locale --reset "LANG=$TARGET_LOCALE" LANGUAGE=zh_CN:zh >/dev/null 2>&1
    fi
    if ! lang_ok; then
        log "语言：尝试直接写配置文件…"
        for f in /etc/default/locale /etc/locale.conf; do
            [ -e "$f" ] || continue
            run_root sh -c "printf 'LANG=$TARGET_LOCALE\nLANGUAGE=zh_CN:zh\n' > $f" && wrote=1
        done
        if [ "$wrote" = "0" ]; then
            run_root sh -c "printf 'LANG=$TARGET_LOCALE\nLANGUAGE=zh_CN:zh\n' > /etc/locale.conf"
        fi
    fi
    # 桌面环境按用户记语言，尽量一起改；失败不算错。
    if command -v busctl >/dev/null 2>&1; then
        busctl call org.freedesktop.Accounts "/org/freedesktop/Accounts/User$(id -u)" \
            org.freedesktop.Accounts.User SetLanguage s "$TARGET_LOCALE" >/dev/null 2>&1
        busctl call org.freedesktop.Accounts "/org/freedesktop/Accounts/User$(id -u)" \
            org.freedesktop.Accounts.User SetFormatsLocale s "$TARGET_LOCALE" >/dev/null 2>&1
    fi
    if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.system.locale region "$TARGET_LOCALE" >/dev/null 2>&1
    fi
    # Debian / Ubuntu 的界面翻译在单独的语言包里，没装的话界面仍是英文。
    if command -v dpkg >/dev/null 2>&1 && ! dpkg -s language-pack-zh-hans >/dev/null 2>&1; then
        info_item "提示：没有检测到中文语言包，界面可能仍是英文；可执行 sudo apt install language-pack-zh-hans language-pack-gnome-zh-hans"
    fi
    lang_ok
}

# 输入法：优先恢复 xiaochuan-env 最早一次备份里的输入法列表；没有备份就加回「ABC + 简体拼音」。
set_keyboard_mac() {
    local plist="$HOME/Library/Preferences/com.apple.HIToolbox.plist" old
    local abc='<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout ID</key><integer>252</integer><key>KeyboardLayout Name</key><string>ABC</string></dict>'
    local py_mode='<dict><key>Bundle ID</key><string>com.apple.inputmethod.SCIM</string><key>Input Mode</key><string>com.apple.inputmethod.SCIM.ITABC</string><key>InputSourceKind</key><string>Input Mode</string></dict>'
    local py='<dict><key>Bundle ID</key><string>com.apple.inputmethod.SCIM</string><key>InputSourceKind</key><string>Keyboard Input Method</string></dict>'
    backup_file "$plist" "keyboard/com.apple.HIToolbox.plist"
    old="$(oldest_backup "keyboard/com.apple.HIToolbox.plist")"
    # 备份里有输入法（不只是键盘布局）才用它，否则恢复出来还是只有美式键盘。
    if [ -n "$old" ] && plutil -p "$old" 2>/dev/null | grep -q 'inputmethod'; then
        log "输入法：恢复修改前的输入法列表（$old）"
        if run defaults import com.apple.HIToolbox "$old"; then
            return 0
        fi
        warn "备份导入失败，改为加回默认的「ABC + 简体拼音」。"
    fi
    run defaults write com.apple.HIToolbox AppleEnabledInputSources -array "$abc" "$py_mode" "$py" || return 1
    run defaults write com.apple.HIToolbox AppleSelectedInputSources -array "$abc" || return 1
    run defaults write com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID -string com.apple.keylayout.ABC || return 1
    return 0
}

set_keyboard_linux() {
    local fcitx="${XDG_CONFIG_HOME:-$HOME/.config}/fcitx5/profile" old snap sources=""
    # fcitx5：有修改前的备份就恢复，否则写成「美式键盘 + 拼音」。
    if [ -f "$fcitx" ]; then
        backup_file "$fcitx" "keyboard/fcitx5-profile"
        old="$(oldest_backup "keyboard/fcitx5-profile")"
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）恢复 fcitx5 输入法列表（有备份用备份，否则 keyboard-us + pinyin）"
        elif [ -n "$old" ]; then
            cp "$old" "$fcitx" || return 1
        else
            printf '%s\n' '[Groups/0]' 'Name=Default' 'Default Layout=us' 'DefaultIM=pinyin' '' \
                '[Groups/0/Items/0]' 'Name=keyboard-us' 'Layout=' '' \
                '[Groups/0/Items/1]' 'Name=pinyin' 'Layout=' '' '[GroupOrder]' '0=Default' > "$fcitx" || return 1
        fi
    fi
    # GNOME 输入源和 ibus；没有对应桌面时失败不算错。
    if command -v gsettings >/dev/null 2>&1; then
        # 修改前的输入源记在最早一次的设置快照里（形如 [('xkb', 'us'), ('ibus', 'libpinyin')]）。
        snap="$(oldest_backup "settings-snapshot.txt")"
        if [ -n "$snap" ]; then
            sources="$(grep "^\[('" "$snap" 2>/dev/null | head -n 1)"
        fi
        case "$sources" in
            *"'ibus'"*) ;;
            *)
                sources=""
                if command -v ibus >/dev/null 2>&1 && ibus list-engine 2>/dev/null | grep -q 'libpinyin'; then
                    sources="[('xkb', 'us'), ('ibus', 'libpinyin')]"
                fi ;;
        esac
        if [ -n "$sources" ]; then
            run gsettings set org.gnome.desktop.input-sources sources "$sources" >/dev/null 2>&1
        else
            info_item "提示：没有找到可以自动加回的中文输入法，请到 设置 > 键盘 > 输入源 手动添加"
        fi
        run gsettings reset org.freedesktop.ibus.general preload-engines >/dev/null 2>&1
    fi
    return 0
}

set_language() {
    [ "$DO_LANG" = "1" ] || return 0
    log "准备把系统语言 / 区域改回简体中文（中国）…"
    if [ "$OS" = "mac" ]; then
        set_language_mac || { fail "语言设置失败。"; return 1; }
        set_keyboard_mac || { fail "输入法设置失败。"; return 1; }
    else
        set_language_linux || { fail "语言设置失败。"; return 1; }
        set_keyboard_linux || { fail "输入法设置失败。"; return 1; }
    fi
    [ "$DRY_RUN" = "1" ] && return 0
    log "语言 / 区域已改回简体中文，中文输入法已加回；注销或重启后生效。"
}

# ------------------------------------------------------------------- 定位

# macOS「定位服务」总开关：1 开，0 关，空表示读不到（这个值只有管理员权限才读得到）。
loc_enabled_mac() {
    local v=""
    have_root || return 0
    v="$(sudo -n -u _locationd defaults -currentHost read com.apple.locationd LocationServicesEnabled 2>/dev/null)"
    if [ -z "$v" ]; then
        v="$(sudo -n defaults read /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled 2>/dev/null)"
    fi
    printf '%s' "$v"
}

geoclue_present() {
    command -v systemctl >/dev/null 2>&1 && systemctl cat geoclue.service >/dev/null 2>&1
}

# 系统定位服务的状态：输出 off / on / unknown。
loc_state() {
    if [ "$OS" = "mac" ]; then
        case "$(loc_enabled_mac)" in
            0) echo off ;;
            1) echo on ;;
            *) echo unknown ;;
        esac
        return 0
    fi
    # GeoClue 还被屏蔽着，或者 GNOME 的开关还是关的，都算没打开。
    if geoclue_present && [ "$(systemctl is-enabled geoclue.service 2>/dev/null)" = "masked" ]; then
        echo off
        return 0
    fi
    if command -v gsettings >/dev/null 2>&1 \
        && [ "$(gsettings get org.gnome.system.location enabled 2>/dev/null)" = "false" ]; then
        echo off
        return 0
    fi
    echo on
}

enable_location_mac() {
    run_root sudo -u _locationd defaults -currentHost write com.apple.locationd LocationServicesEnabled -int 1 >/dev/null 2>&1
    if [ "$(loc_enabled_mac)" != "1" ]; then
        run_root defaults write /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled -int 1 >/dev/null 2>&1
    fi
    run_root killall locationd >/dev/null 2>&1
    sleep 1
    [ "$(loc_enabled_mac)" = "1" ]
}

enable_location_linux() {
    if geoclue_present; then
        run_root systemctl unmask geoclue.service >/dev/null 2>&1
    fi
    if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.system.location enabled true >/dev/null 2>&1
    fi
    [ "$(loc_state)" = "on" ]
}

set_location() {
    [ "$DO_LOC" = "1" ] || return 0
    log "准备打开系统定位服务…"
    if [ "$DRY_RUN" = "1" ]; then
        if [ "$OS" = "mac" ]; then
            log "（演练）打开 系统设置 > 隐私与安全性 > 定位服务 的总开关"
        else
            log "（演练）取消屏蔽 GeoClue 定位服务，并打开 GNOME 的「定位服务」开关"
        fi
        return 0
    fi
    if [ "$OS" = "mac" ]; then
        if ! enable_location_mac; then
            fail "系统定位服务没打开（新版 macOS 可能不让脚本改）；请到 系统设置 > 隐私与安全性 > 定位服务 手动打开。"
            return 1
        fi
    elif ! enable_location_linux; then
        fail "系统定位服务没打开；请到 设置 > 隐私 > 定位服务 手动打开。"
        return 1
    fi
    log "系统定位服务已打开。"
}

# ------------------------------------------------------------------- IPv6

# macOS：IPv6 还是「关闭」的网络服务（Wi-Fi、以太网…），每行一个；已停用的服务不算。
ip6_off_services_mac() {
    local svc
    networksetup -listallnetworkservices 2>/dev/null | sed '1d' | grep -v '^\*' | while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        networksetup -getinfo "$svc" 2>/dev/null | grep -q '^IPv6: Off' && printf '%s\n' "$svc"
    done
}

# 系统 IPv6 的状态：输出 on / off / none（内核里根本没有 IPv6，不是脚本关的）。
ip6_state() {
    if [ "$OS" = "mac" ]; then
        if [ -z "$(ip6_off_services_mac)" ]; then echo on; else echo off; fi
        return 0
    fi
    if [ ! -d /proc/sys/net/ipv6 ]; then echo none; return 0; fi
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "0" ] \
        && [ "$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)" = "0" ] \
        && [ ! -e "$IP6_SYSCTL_FILE" ]; then
        echo on
    else
        echo off
    fi
}

# macOS：把每个网络服务的 IPv6 改回「自动」。
enable_ip6_mac() {
    local svc list
    list="$(ip6_off_services_mac)"
    # 列表走 3 号描述符，免得 sudo 把它当成输入读走。
    while IFS= read -r svc <&3; do
        [ -n "$svc" ] || continue
        run_root networksetup -setv6automatic "$svc" >/dev/null 2>&1
    done 3<<IP6_EOF
$list
IP6_EOF
    [ "$(ip6_state)" = "on" ]
}

# Linux：删掉让重启后保持关闭的配置文件，并马上打开（sysctl）。
enable_ip6_linux() {
    run_root rm -f "$IP6_SYSCTL_FILE" >/dev/null 2>&1
    run_root sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    if [ "$(ip6_state)" != "on" ]; then
        run_root sh -c 'echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6; echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6' >/dev/null 2>&1
    fi
    [ "$(ip6_state)" = "on" ]
}

set_ip6() {
    [ "$DO_IP6" = "1" ] || return 0
    log "准备打开系统 IPv6…"
    if [ "$DRY_RUN" = "1" ]; then
        if [ "$OS" = "mac" ]; then
            log "（演练）把每个网络服务（Wi-Fi、以太网…）的 IPv6 改回「自动」"
        else
            log "（演练）删除 $IP6_SYSCTL_FILE，并用 sysctl 打开 IPv6"
        fi
        return 0
    fi
    case "$(ip6_state)" in
        on) log "系统 IPv6 已经是打开的，无需修改。"; return 0 ;;
        none) log "这个系统的内核没有启用 IPv6（不是脚本关的），已跳过。"; return 0 ;;
    esac
    if [ "$OS" = "mac" ]; then
        if ! enable_ip6_mac; then
            fail "系统 IPv6 没打开，这些网络服务还是关的：$(ip6_off_services_mac | tr '\n' ' ')；请到 系统设置 > 网络 > 详细信息 > TCP/IP 把「配置 IPv6」改成「自动」。"
            return 1
        fi
    elif ! enable_ip6_linux; then
        fail "系统 IPv6 没打开（需要管理员权限）。"
        return 1
    fi
    log "系统 IPv6 已打开（拿到 IPv6 地址可能要等几秒，或重新连一次网络）。"
}

# ----------------------------------------------------------------- 主流程

# 状态里的一行：$1 是 ✓ 或 ✗。已还原的绿色，还没还原的红色并计数。
status_line() {
    if [ "$1" = "✓" ]; then
        printf '  %s✓ %s%s\n' "$C_OK" "$2" "$C_OFF"
    else
        printf '  %s✗ %s%s\n' "$C_BAD" "$2" "$C_OFF"
        STATUS_BAD=$((STATUS_BAD + 1))
    fi
}

# 逐项显示当前状态，✓ 表示已经是中国 / 中文的设置，✗ 表示还没还原。
status() {
    local tz lang cl t_ok="✗" l_ok="✗" c_ok="✗" geo_off=""
    tz="$(current_tz)"
    lang="$(current_lang)"
    [ "$tz" = "$TARGET_TZ" ] && t_ok="✓"
    lang_ok && l_ok="✓"

    STATUS_BAD=0
    status_line "$t_ok" "时区：${tz:-未知}（目标 $TARGET_TZ）"
    status_line "$l_ok" "系统语言：${lang:-未知}（目标 简体中文）"
    case "$(loc_state)" in
        on) status_line "✓" "系统定位：已打开" ;;
        off) status_line "✗" "系统定位：关着（目标 打开）" ;;
        *) echo "  - 系统定位：现在读不到（要管理员权限）；执行「打开系统定位」后会核对" ;;
    esac
    case "$(ip6_state)" in
        on) status_line "✓" "系统 IPv6：已打开" ;;
        off) status_line "✗" "系统 IPv6：关着（目标 打开）" ;;
        *) echo "  - 系统 IPv6：内核没有启用 IPv6（不是脚本关的）" ;;
    esac
    if [ -f "$CHROME_DATA/Local State" ]; then
        cl="$(chrome_lang)"
        [ "$cl" = "zh-CN" ] && c_ok="✓"
        status_line "$c_ok" "Chrome 语言：${cl:-未设置，跟随系统}（目标 zh-CN）"
        geo_off="$(chrome_geo_off_profiles)"
        if [ -z "$geo_off" ]; then
            status_line "✓" "Chrome 定位：没有被禁止"
        else
            status_line "✗" "Chrome 定位：这些个人资料还是「禁止」：$geo_off（目标 网站可以询问）"
        fi
    else
        echo "  - Chrome：未检测到"
    fi
}

# 执行后逐项核对「选中的项目」有没有真的还原；没还原的记为失败。
verify_results() {
    local want_chrome="$1" want_tz="$2" want_lang="$3" want_loc="$4" want_ip6="$5" cl geo_off
    if [ "$want_tz" = "1" ]; then
        if [ "$(current_tz)" = "$TARGET_TZ" ]; then
            ok_item "时区：$(current_tz)"
        else
            bad_item "时区：当前是 $(current_tz)，目标 $TARGET_TZ"
        fi
    fi
    if [ "$want_lang" = "1" ]; then
        if lang_ok; then
            ok_item "系统语言：$(current_lang)（注销或重启后完全生效）"
        else
            bad_item "系统语言：当前是 $(current_lang)，目标 简体中文"
        fi
    fi
    if [ "$want_loc" = "1" ]; then
        case "$(loc_state)" in
            on) ok_item "系统定位：定位服务已打开" ;;
            off) bad_item "系统定位：定位服务还关着" ;;
            *) bad_item "系统定位：无法确认是否已打开，请到 系统设置 > 隐私与安全性 > 定位服务 看一下" ;;
        esac
    fi
    if [ "$want_ip6" = "1" ]; then
        case "$(ip6_state)" in
            on) ok_item "系统 IPv6：已打开" ;;
            off) bad_item "系统 IPv6：还关着" ;;
            *) info_item "系统 IPv6：内核没有启用 IPv6（不是脚本关的），未处理" ;;
        esac
    fi
    if [ "$want_chrome" = "1" ]; then
        if [ ! -d "$CHROME_DATA" ]; then
            info_item "Chrome：这台电脑没有装 Chrome，无需处理"
        else
            cl="$(chrome_lang)"
            geo_off="$(chrome_geo_off_profiles)"
            if [ "$cl" != "zh-CN" ]; then
                bad_item "Chrome 语言：当前是 ${cl:-未设置}，目标 zh-CN"
            elif [ -n "$geo_off" ]; then
                bad_item "Chrome 定位：这些个人资料还是「禁止」：$geo_off"
            else
                ok_item "Chrome：语言 zh-CN，定位已恢复为「网站可以询问」"
            fi
        fi
    fi
}

run_pipeline() {
    if [ "$DO_CHROME$DO_TZ$DO_LANG$DO_LOC$DO_IP6" = "00000" ]; then
        echo "请至少选择一个执行项目。"
        return 1
    fi
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$DATA_DIR/restore-backups/$STAMP"

    [ "$DRY_RUN" = "1" ] && log "演练模式：只显示将要做的事，不做任何修改。"
    local want_chrome="$DO_CHROME" want_tz="$DO_TZ" want_lang="$DO_LANG" want_loc="$DO_LOC" want_ip6="$DO_IP6"

    # 一开始就拿管理员权限：时区、定位、IPv6、Linux 语言都要用。
    if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" != "0" ] \
        && [ "$DO_TZ$DO_LANG$DO_LOC$DO_IP6" != "0000" ]; then
        log "先申请管理员权限，请输入本机登录密码（输入时屏幕上不显示，输完按回车）。"
        if ! command -v sudo >/dev/null 2>&1 || ! sudo -v; then
            NO_ROOT=1
            fail "没有拿到管理员权限（密码不对，或当前账户不是管理员）。时区等必须用管理员权限的项目会失败。"
        fi
    fi

    set_timezone
    set_language
    set_location
    set_ip6
    restore_chrome

    if [ "$DRY_RUN" = "1" ]; then
        skip "演练结束，没有做任何修改。"
        return 0
    fi

    verify_results "$want_chrome" "$want_tz" "$want_lang" "$want_loc" "$want_ip6"
    if [ "$want_lang" = "1" ]; then
        info_item "提示：语言和输入法设置需要注销或重启电脑后才完全生效"
    fi
    [ "$BAD_COUNT" = "0" ]
}

menu() {
    local c picked bad choices
    while :; do
        DO_CHROME=0; DO_TZ=0; DO_LANG=0; DO_LOC=0; DO_IP6=0
        ERRORS=0; RESULTS=""; OK_COUNT=0; BAD_COUNT=0
        picked=0; bad=0

        echo
        echo "================ 小川环境还原助手 $VERSION（$OS）================"
        status
        echo
        echo "  1) Chrome 语言改回 zh-CN，并恢复 Chrome 定位（网站可以询问）"
        echo "  2) 时区改回 $TARGET_TZ（北京时间）"
        echo "  3) 系统语言 / 区域改回简体中文（中国），加回中文输入法"
        echo "  4) 打开系统定位服务"
        echo "  5) 打开系统 IPv6"
        echo "  a) 一键执行 1 2 3 4 5（推荐）"
        echo "  q) 退出"
        echo
        printf '请输入要执行的项目（可多选，用空格分开，例如 2 3），然后按回车：'
        read -r choices || exit 0

        # 允许用逗号分隔；关掉通配符展开，免得输入 * 之类被当成文件名。
        set -f
        # shellcheck disable=SC2086
        set -- $(printf '%s' "$choices" | tr ',' ' ')
        set +f
        for c in "$@"; do
            case "$c" in
                1) DO_CHROME=1; picked=1 ;;
                2) DO_TZ=1; picked=1 ;;
                3) DO_LANG=1; picked=1 ;;
                4) DO_LOC=1; picked=1 ;;
                5) DO_IP6=1; picked=1 ;;
                a|A) DO_CHROME=1; DO_TZ=1; DO_LANG=1; DO_LOC=1; DO_IP6=1; picked=1 ;;
                q|Q) exit 0 ;;
                *) echo "看不懂的选项：$c"; bad=1; break ;;
            esac
        done

        if [ "$bad" = "0" ]; then
            [ "$picked" = "1" ] || continue
            run_pipeline
            print_result
        fi

        echo
        printf '按回车返回菜单（输入 q 退出）：'
        read -r c || exit 0
        case "$c" in q|Q) exit 0 ;; esac
    done
}

usage() {
    cat <<EOF
小川环境还原助手 $VERSION（macOS / Linux）
把 xiaochuan-env.sh 改过的设置还原成中国 / 中文。

用法：
  bash $0                  交互菜单（不带参数）
  bash $0 [选项]           按选项直接执行
  bash $0 status           检查当前状态（时区 / 语言 / 定位 / IPv6 / Chrome 是否已还原）

选项：
  --chrome       Chrome 语言改回 zh-CN，并恢复 Chrome 定位（网站可以询问）
  --timezone     时区改回 $TARGET_TZ
  --language     系统语言 / 区域改回简体中文（中国），并加回中文输入法
  --location     打开系统定位服务
  --ipv6         打开系统 IPv6
  --all          等于 --chrome --timezone --language --location --ipv6
  --dry-run      演练：只显示将要做的事，不做任何修改
  -h, --help     显示本说明

不要在前面加 sudo：脚本会在需要时自己申请管理员权限，只要输一次密码。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --chrome) DO_CHROME=1 ;;
        --timezone) DO_TZ=1 ;;
        --language) DO_LANG=1 ;;
        --location) DO_LOC=1 ;;
        --ipv6) DO_IP6=1 ;;
        --all) DO_CHROME=1; DO_TZ=1; DO_LANG=1; DO_LOC=1; DO_IP6=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        status) ACTION="$1" ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

case "$ACTION" in
    status)
        echo "小川环境还原助手 $VERSION（$OS）"
        status
        echo "=========================================="
        if [ "$STATUS_BAD" = "0" ]; then
            printf '%s 结果：时区、语言、定位、IPv6 都已还原 %s\n' "$C_OK_BAR" "$C_OFF"
        else
            printf '%s 结果：有 %s 项还没还原（上面标 ✗ 的红色行） %s\n' "$C_BAD_BAR" "$STATUS_BAD" "$C_OFF"
        fi
        [ "$STATUS_BAD" = "0" ]
        exit $?
        ;;
    "")
        if [ "$DO_CHROME$DO_TZ$DO_LANG$DO_LOC$DO_IP6" != "00000" ]; then
            run_pipeline
        elif [ -t 0 ]; then
            # 菜单里每执行完一次都会打印「执行结果」，这里不用再打印。
            menu
            exit 0
        else
            usage
            exit 2
        fi
        ;;
esac
print_result
[ "$BAD_COUNT" = "0" ]
