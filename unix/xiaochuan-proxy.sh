#!/usr/bin/env bash
# 小川强制代理助手 · macOS / Linux 版
# 按《Windows Claude 强制代理实施方案》的思路，把 Claude Code / Claude Desktop 固定到 Clash 本地代理上：
#   找到 Clash 本地代理端口并测试（没有 Clash 客户端时按 CPU 架构下载安装 Clash Verge Rev）、
#   给 Claude Code 写入自身代理设置（代理不通就连接失败）、
#   macOS：下载安装 Proxifier 并写入 Claude 专用规则（其他软件保持直连）、
#   Linux：可选，让 Chrome / Edge / Chromium 里 Claude 的网站强制走代理。
# 兼容 macOS 自带的 bash 3.2：不使用关联数组、mapfile、${var,,} 等新语法。

VERSION="1.0.0"
PROXY_HOST="127.0.0.1"
TEST_URL="https://api.anthropic.com/"
# 这些域名：Proxifier 里通过代理解析（不走本机 DNS），浏览器里强制走代理。
CLAUDE_DOMAINS="claude.ai claude.com anthropic.com claudeusercontent.com"
MARKER="xiaochuan-proxy"

PROXIFIER_URL="https://www.proxifier.com/download/ProxifierMac.dmg"
CLASH_API="https://api.github.com/repos/clash-verge-rev/clash-verge-rev/releases/latest"
CLASH_FALLBACK_VER="2.5.10"

case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux) OS="linux" ;;
    *) echo "只支持 macOS 和 Linux。" >&2; exit 1 ;;
esac

# 用 sudo 整个运行会把 Claude Code 设置、Proxifier 配置这些「用户级」文件写到 root 账户上，
# 所以这里退回原用户身份重新执行，需要管理员权限的步骤由脚本自己逐条 sudo。
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -f "$0" ]; then
    echo "检测到用 sudo 运行：改回用户 $SUDO_USER 的身份执行，需要管理员权限的步骤会自动提权。"
    exec sudo -u "$SUDO_USER" -H -- bash "$0" "$@"
fi

DATA_DIR="$HOME/.xiaochuan-env"
DOWNLOAD_DIR="$DATA_DIR/downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$DATA_DIR/proxy-backups/$STAMP"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
PX_APP="/Applications/Proxifier.app"
PX_PROFILE_DIR="$HOME/Library/Application Support/Proxifier/Profiles"
PX_PROFILE="$PX_PROFILE_DIR/xiaochuan-claude.ppx"
# Linux 上各浏览器读「策略」的目录；写在这里的代理设置，扩展和用户设置都改不了。
POLICY_DIRS="/etc/opt/chrome/policies/managed /etc/opt/edge/policies/managed /etc/chromium/policies/managed"
POLICY_NAME="xiaochuan-proxy.json"

DRY_RUN=0
DO_CODE=0
DO_PX=0
DO_BROWSER=0
ACTION=""
OPT_PORT=""
OPT_TYPE=""
BROWSER_MODE="claude"
LOCAL_DNS=0

ERRORS=0
NO_ROOT=0
STATUS_BAD=0
# 找到的 Clash 本地代理：端口为空表示没有这种入口。
PX_SOCKS=""
PX_HTTP=""
PX_TYPE=""
PX_PORT=""

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

# 申请管理员权限（只问一次密码）；拿不到返回 1。
need_root() {
    [ "$(id -u)" = "0" ] && return 0
    [ "$NO_ROOT" = "1" ] && return 1
    sudo -n true >/dev/null 2>&1 && return 0
    log "这一步需要管理员权限，请输入本机登录密码（输入时屏幕上不显示，输完按回车）。"
    if command -v sudo >/dev/null 2>&1 && sudo -v; then
        return 0
    fi
    NO_ROOT=1
    return 1
}

backup_file() {
    local src="$1" rel="$2"
    [ -f "$src" ] || return 0
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")" && cp -p "$src" "$BACKUP_DIR/$rel"
}

# ------------------------------------------------------- Clash 本地代理入口

# 本机这个端口有没有程序在监听。
port_open() {
    (exec 3<>"/dev/tcp/$PROXY_HOST/$1") >/dev/null 2>&1
}

# 通过代理访问 Claude 的服务器，输出 HTTP 状态码；不通输出 000。$1：socks5h 或 http  $2：端口
proxy_http_code() {
    local code
    code="$(curl -s -o /dev/null --connect-timeout 5 -m 20 -w '%{http_code}' -x "$1://$PROXY_HOST:$2" "$TEST_URL" 2>/dev/null)"
    case "$code" in
        [1-5][0-9][0-9]) printf '%s' "$code" ;;
        *) printf '000' ;;
    esac
}

# Clash 类客户端的配置目录（每行一个）。
clash_config_dirs() {
    if [ "$OS" = "mac" ]; then
        printf '%s\n' \
            "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" \
            "$HOME/Library/Application Support/mihomo-party" \
            "$HOME/Library/Application Support/mihomo-party/work" \
            "$HOME/Library/Application Support/sparkle"
    else
        printf '%s\n' \
            "${XDG_DATA_HOME:-$HOME/.local/share}/io.github.clash-verge-rev.clash-verge-rev" \
            "${XDG_CONFIG_HOME:-$HOME/.config}/mihomo-party" \
            "${XDG_CONFIG_HOME:-$HOME/.config}/mihomo-party/work"
    fi
    printf '%s\n' "$HOME/.config/clash-verge" "$HOME/.config/clash" "$HOME/.config/mihomo"
}

# 可能是 Clash 本地代理端口的候选（每行一个，已去重）：配置文件里写的、Clash 进程正在监听的、常见默认值。
proxy_candidates() {
    local d f
    {
        # 只取端口号，文件里的其他内容（订阅、密码）不读出来、不显示。
        clash_config_dirs | while IFS= read -r d; do
            for f in "$d/verge.yaml" "$d/config.yaml" "$d/clash-verge.yaml" "$d/mihomo.yaml"; do
                [ -f "$f" ] || continue
                sed -n -E 's/^(verge_mixed_port|mixed-port|verge_socks_port|socks-port|verge_port|port)[[:space:]]*:[[:space:]]*([0-9]{2,5})[[:space:]]*$/\2/p' "$f" 2>/dev/null
            done
        done
        if [ "$OS" = "mac" ]; then
            lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
                | grep -iE '^(clash|mihomo|verge|sing-box|flclash|sparkle|v2ray|xray)' \
                | sed -n -E 's/.*:([0-9]+) \(LISTEN\).*/\1/p'
        elif command -v ss >/dev/null 2>&1; then
            ss -ltnpH 2>/dev/null | grep -iE '"[^"]*(clash|mihomo|verge|sing-box|flclash|sparkle|v2ray|xray)' \
                | sed -n -E 's/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]*:([0-9]+) .*/\1/p'
        fi
        printf '%s\n' 7897 7890 7893 7891 7898 7899 10808 10809 1080
    } | awk 'NF && !seen[$1]++'
}

# 找 Clash 本地代理入口。优先选「SOCKS5 和 HTTP 都支持」的混合端口；找到返回 0，结果放在 PX_* 里。
find_proxy() {
    local list p s h
    PX_SOCKS=""; PX_HTTP=""; PX_TYPE=""; PX_PORT=""
    if [ -n "$OPT_PORT" ]; then list="$OPT_PORT"; else list="$(proxy_candidates)"; fi
    for p in $list; do
        port_open "$p" || continue
        s=0; h=0
        [ "$(proxy_http_code socks5h "$p")" != "000" ] && s=1
        [ "$(proxy_http_code http "$p")" != "000" ] && h=1
        if [ "$s" = "1" ] && [ "$h" = "1" ]; then PX_SOCKS="$p"; PX_HTTP="$p"; break; fi
        [ "$s" = "1" ] && [ -z "$PX_SOCKS" ] && PX_SOCKS="$p"
        [ "$h" = "1" ] && [ -z "$PX_HTTP" ] && PX_HTTP="$p"
    done
    [ -n "$PX_SOCKS$PX_HTTP" ] || return 1
    PX_TYPE="socks5"; PX_PORT="$PX_SOCKS"
    if [ -z "$PX_SOCKS" ] || [ "$OPT_TYPE" = "http" ]; then
        [ -n "$PX_HTTP" ] || return 1
        PX_TYPE="http"; PX_PORT="$PX_HTTP"
    fi
    return 0
}

proxy_text() {
    if [ -z "$PX_PORT" ]; then printf '没找到'; return 0; fi
    if [ "$PX_SOCKS" = "$PX_HTTP" ]; then
        printf '%s:%s（混合端口：SOCKS5 + HTTP）' "$PROXY_HOST" "$PX_PORT"
    else
        [ -n "$PX_SOCKS" ] && printf 'SOCKS5 %s:%s ' "$PROXY_HOST" "$PX_SOCKS"
        [ -n "$PX_HTTP" ] && printf 'HTTP %s:%s' "$PROXY_HOST" "$PX_HTTP"
    fi
}

# 有没有候选端口在监听（用来区分「Clash 没开」和「Clash 开着但节点不通」）。
any_candidate_open() {
    local p list
    if [ -n "$OPT_PORT" ]; then list="$OPT_PORT"; else list="$(proxy_candidates)"; fi
    for p in $list; do
        port_open "$p" && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# 这台电脑上有没有 Clash 类客户端。
clash_installed() {
    local d a
    while IFS= read -r d; do
        [ -d "$d" ] && return 0
    done <<DIRS_EOF
$(clash_config_dirs)
DIRS_EOF
    if [ "$OS" = "mac" ]; then
        for a in /Applications/Clash*.app /Applications/clash*.app /Applications/Mihomo*.app /Applications/FlClash*.app \
            /Applications/Sparkle*.app /Applications/V2ray*.app "$HOME"/Applications/Clash*.app; do
            [ -d "$a" ] && return 0
        done
        return 1
    fi
    for a in clash-verge clash mihomo mihomo-party flclash; do
        command -v "$a" >/dev/null 2>&1 && return 0
    done
    return 1
}

# CPU 架构：arm64 或 x64。Apple 芯片的 Mac 在 Rosetta 下运行脚本时 uname 会说 x86_64，所以另外问一下系统。
cpu_arch() {
    if [ "$OS" = "mac" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
        echo arm64
        return 0
    fi
    case "$(uname -m)" in
        arm64|aarch64) echo arm64 ;;
        *) echo x64 ;;
    esac
}

# 下载文件：先直接下，不行再通过 Clash 代理下。$1 网址  $2 保存位置
download() {
    local url="$1" dest="$2" tmp="$2.part"
    mkdir -p "$(dirname "$dest")" || return 1
    rm -f "$tmp"
    if ! curl -fsSL --connect-timeout 15 -m 900 -o "$tmp" "$url" 2>/dev/null; then
        rm -f "$tmp"
        [ -n "$PX_HTTP" ] && curl -fsSL --connect-timeout 15 -m 900 -x "http://$PROXY_HOST:$PX_HTTP" -o "$tmp" "$url" 2>/dev/null
    fi
    # 小于 200 KB 的多半是报错页面，不是安装包。
    if [ -f "$tmp" ] && [ "$(wc -c < "$tmp" | tr -d ' ')" -gt 200000 ]; then
        mv -f "$tmp" "$dest"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# 把 dmg 里的某个 .app 装到 /Applications。$1 dmg 文件  $2 .app 的名字（如 Proxifier.app）
install_app_from_dmg() {
    local dmg="$1" app="$2" mnt src rc=1
    mnt="$(mktemp -d "${TMPDIR:-/tmp}/xc-dmg.XXXXXX")" || return 1
    if ! hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null 2>&1; then
        rmdir "$mnt" 2>/dev/null
        return 1
    fi
    src="$mnt/$app"
    if [ -d "$src" ]; then
        # 没有管理员权限的账户写不了 /Applications，这时用 sudo。
        if ditto "$src" "/Applications/$app" 2>/dev/null || { need_root && run_root ditto "$src" "/Applications/$app"; }; then
            rc=0
        fi
    fi
    hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || hdiutil detach "$mnt" -force -quiet >/dev/null 2>&1
    rmdir "$mnt" 2>/dev/null
    return $rc
}

# 电脑上没有任何 Clash 客户端时：按 CPU 架构下载并安装 Clash Verge Rev。
# 装完还需要用户自己导入订阅，这一步脚本做不了。
install_clash_verge() {
    local arch pattern url="" file
    arch="$(cpu_arch)"
    if [ "$OS" = "mac" ]; then
        if [ "$arch" = "arm64" ]; then pattern="_aarch64.dmg"; else pattern="_x64.dmg"; fi
    elif command -v dpkg >/dev/null 2>&1; then
        if [ "$arch" = "arm64" ]; then pattern="_arm64.deb"; else pattern="_amd64.deb"; fi
    elif command -v rpm >/dev/null 2>&1; then
        if [ "$arch" = "arm64" ]; then pattern=".aarch64.rpm"; else pattern=".x86_64.rpm"; fi
    else
        fail "这台电脑没有 Clash 客户端，而且系统既不是 deb 系也不是 rpm 系，脚本没法自动安装。请手动安装 Clash 客户端后重新运行。"
        return 1
    fi
    url="$(curl -fsSL --connect-timeout 15 -m 30 -H 'User-Agent: xiaochuan-proxy' "$CLASH_API" 2>/dev/null \
        | sed -n -E 's/.*"browser_download_url": *"([^"]+)".*/\1/p' | grep -F -- "$pattern" | head -n 1)"
    if [ -z "$url" ]; then
        case "$pattern" in
            *.rpm) url="https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v$CLASH_FALLBACK_VER/Clash.Verge-$CLASH_FALLBACK_VER-1$pattern" ;;
            *) url="https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v$CLASH_FALLBACK_VER/Clash.Verge_$CLASH_FALLBACK_VER$pattern" ;;
        esac
    fi
    file="$DOWNLOAD_DIR/$(basename "$url")"
    log "这台电脑没有 Clash 客户端，下载 Clash Verge Rev（$arch）：$url"
    if ! download "$url" "$file"; then
        fail "Clash Verge Rev 下载失败（GitHub 在没有代理时经常连不上）。请手动下载安装：$url"
        return 1
    fi
    log "正在安装 Clash Verge Rev…"
    if [ "$OS" = "mac" ]; then
        install_app_from_dmg "$file" "Clash Verge.app" || { fail "Clash Verge Rev 安装失败（dmg 打不开，或没法写入 /Applications）。安装包在：$file"; return 1; }
        # 这个软件没有经过 Apple 公证，去掉隔离标记，否则第一次打开会被系统拦住。
        xattr -dr com.apple.quarantine "/Applications/Clash Verge.app" >/dev/null 2>&1
    else
        need_root || { fail "没有管理员权限，装不了 Clash Verge Rev。安装包在：$file"; return 1; }
        case "$file" in
            *.deb) run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$file" >/dev/null 2>&1 \
                    || run_root dpkg -i "$file" >/dev/null 2>&1 \
                    || { fail "Clash Verge Rev 安装失败。可以手动执行：sudo apt install $file"; return 1; } ;;
            *.rpm) { run_root dnf install -y "$file" >/dev/null 2>&1 || run_root rpm -Uvh "$file" >/dev/null 2>&1; } \
                    || { fail "Clash Verge Rev 安装失败。可以手动执行：sudo dnf install $file"; return 1; } ;;
        esac
    fi
    log "Clash Verge Rev 已安装。"
    return 0
}

# 确保有一个能用的 Clash 本地代理入口；后面每一步都要用它。
init_proxy() {
    local open
    log "正在找 Clash 本地代理入口…"
    if ! command -v curl >/dev/null 2>&1; then
        fail "这台电脑没有 curl，脚本要用它测试代理。请先安装 curl（Ubuntu：sudo apt install curl）。"
        return 1
    fi
    if find_proxy; then
        log "Clash 本地代理入口：$(proxy_text)；通过它访问 Claude 服务器：通。"
        return 0
    fi
    if [ -n "$OPT_PORT" ]; then
        fail "指定的端口 $PROXY_HOST:$OPT_PORT 连不上 Claude 的服务器：它不是 SOCKS5 / HTTP 代理入口，或者 Clash 的节点不可用。请到 Clash 的端口设置里核对 Mixed Port。"
        return 1
    fi
    open="$(any_candidate_open)"
    if [ -n "$open" ]; then
        fail "端口 $PROXY_HOST:$open 在监听，但通过它连不上 Claude 的服务器：Clash 的节点不可用，或这个端口不是代理入口。请在 Clash 里换一个能用的节点；端口不对时用 --proxy-port 指定。"
        return 1
    fi
    if ! clash_installed; then
        if [ "$DRY_RUN" = "1" ]; then
            skip "（演练）这台电脑没有 Clash 客户端；正式执行时会下载并安装 Clash Verge Rev（$(cpu_arch)）。"
            return 1
        fi
        if install_clash_verge; then
            fail "Clash Verge Rev 已装好，但还没有订阅：请打开 Clash Verge，导入你的订阅并选好节点，然后重新运行本脚本（订阅链接只有你有，脚本做不了这一步）。"
        fi
        return 1
    fi
    fail "检测到已安装 Clash 客户端，但没找到在监听的本地代理端口。请先打开 Clash、确认节点可用；端口不是常见值时用 --proxy-port 指定（在 Clash 的端口设置里看 Mixed Port）。"
    return 1
}

# ------------------------------------------------- Claude Code 自身代理设置

code_proxy_url() {
    [ -n "$PX_HTTP" ] && printf 'http://%s:%s' "$PROXY_HOST" "$PX_HTTP"
}

# 改 Claude Code 的 settings.json。$1：set（写入代理）或 unset（删掉我们写的代理）  $2：代理地址
# 文件不是合法 JSON 时报错退出，不去覆盖它。
edit_settings_perl() {
    perl -MJSON::PP -e '
        my ($file, $mode, $url) = @ARGV;
        my $json = JSON::PP->new->utf8->pretty->canonical;
        my $data = {};
        if (-s $file) {
            local $/;
            open(my $in, "<", $file) or die "open: $!";
            $data = $json->decode(<$in>);
            close($in);
            die "not a JSON object" unless ref($data) eq "HASH";
        }
        if ($mode eq "set") {
            $data->{env} = {} unless ref($data->{env}) eq "HASH";
            $data->{env}{HTTPS_PROXY} = $url;
            $data->{env}{HTTP_PROXY} = $url;
            $data->{env}{NO_PROXY} = "localhost,127.0.0.1,::1" unless exists $data->{env}{NO_PROXY};
        } elsif (ref($data->{env}) eq "HASH") {
            # 只删我们写的值（指向本机的代理地址）；用户自己设的别的代理不动。
            for my $k ("HTTPS_PROXY", "HTTP_PROXY") {
                delete $data->{env}{$k} if defined $data->{env}{$k} && $data->{env}{$k} =~ m{^http://127\.0\.0\.1:\d+$};
            }
            delete $data->{env}{NO_PROXY} if defined $data->{env}{NO_PROXY} && $data->{env}{NO_PROXY} eq "localhost,127.0.0.1,::1";
            delete $data->{env} unless %{$data->{env}};
        }
        open(my $out, ">", "$file.xc-tmp") or die "write: $!";
        print $out $json->encode($data);
        close($out) or die "close: $!";
        rename("$file.xc-tmp", $file) or die "rename: $!";
    ' "$CLAUDE_SETTINGS" "$1" "${2:-}"
}

edit_settings_python() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$CLAUDE_SETTINGS" "$1" "${2:-}" <<'PY'
import json, os, re, sys
path, mode, url = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise SystemExit("not a JSON object")
env = data.get("env")
if mode == "set":
    if not isinstance(env, dict):
        env = data["env"] = {}
    env["HTTPS_PROXY"] = url
    env["HTTP_PROXY"] = url
    env.setdefault("NO_PROXY", "localhost,127.0.0.1,::1")
elif isinstance(env, dict):
    for k in ("HTTPS_PROXY", "HTTP_PROXY"):
        if isinstance(env.get(k), str) and re.match(r"^http://127\.0\.0\.1:\d+$", env[k]):
            del env[k]
    if env.get("NO_PROXY") == "localhost,127.0.0.1,::1":
        del env["NO_PROXY"]
    if not env:
        del data["env"]
tmp = path + ".xc-tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
}

edit_settings() {
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")" || return 1
    edit_settings_perl "$1" "${2:-}" 2>/dev/null && return 0
    edit_settings_python "$1" "${2:-}" 2>/dev/null
}

# settings.json 的 env 里 HTTPS_PROXY 的值；没有则输出空。
code_proxy_current() {
    [ -f "$CLAUDE_SETTINGS" ] || return 0
    tr -d '\n' < "$CLAUDE_SETTINGS" 2>/dev/null | sed -n -E 's/.*"HTTPS_PROXY"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p'
}

code_proxy_ok() {
    local want
    want="$(code_proxy_url)"
    [ -n "$want" ] && [ "$(code_proxy_current)" = "$want" ]
}

# 在 Claude Code 的设置里写入 HTTPS_PROXY / HTTP_PROXY：Claude Code 自己只走这个代理，代理不通就连接失败。
set_code_proxy() {
    [ "$DO_CODE" = "1" ] || return 0
    local url
    url="$(code_proxy_url)"
    log "准备给 Claude Code 写入代理设置…"
    if [ -z "$url" ]; then
        fail "Claude Code 只支持 HTTP 代理，但没找到 Clash 的 HTTP / 混合端口。请在 Clash 里打开 Mixed Port（混合端口）后重新运行。"
        return 1
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）在 $CLAUDE_SETTINGS 的 env 里写入 HTTPS_PROXY / HTTP_PROXY = $url"
        return 0
    fi
    backup_file "$CLAUDE_SETTINGS" "claude/settings.json"
    if ! edit_settings set "$url" || ! code_proxy_ok; then
        fail "Claude Code 设置文件修改失败（文件：$CLAUDE_SETTINGS；内容不是合法 JSON 时脚本不会去覆盖它）。"
        return 1
    fi
    log "Claude Code 代理已设为 $url（重新打开 Claude Code 后生效）。"
}

# ------------------------------------------------------- Proxifier（macOS）

proxifier_running() {
    pgrep -x Proxifier >/dev/null 2>&1
}

# 写进 Proxifier 规则的程序列表（macOS 版 Proxifier 按「可执行文件名」匹配，和路径无关）：
# Claude Desktop 的主程序和辅助进程、Claude Code（claude，以及文件名是版本号的原生版本）。
proxifier_apps() {
    local list='Claude; "Claude Helper*"; claude' f
    for f in "$HOME/.local/share/claude/versions"/*; do
        [ -f "$f" ] && [ -s "$f" ] || continue
        list="$list; $(basename "$f")"
    done
    printf '%s' "$list"
}

# 我们生成的配置文件里记的代理端口；文件不存在或不是我们生成的输出空。
profile_port() {
    [ -f "$PX_PROFILE" ] || return 0
    grep -q "$MARKER" "$PX_PROFILE" 2>/dev/null || return 0
    sed -n -E 's/.*<Port>([0-9]+)<\/Port>.*/\1/p' "$PX_PROFILE" | head -n 1
}

# 生成 Proxifier 配置：Claude 的程序走 Clash 代理，本机地址和其他所有软件保持直连。
# 规则里没有「代理失败后直连」这种回退：代理不通，Claude 的连接就失败。
write_profile() {
    local ptype="SOCKS5" options="" via="true" dns="" d
    if [ "$PX_TYPE" = "http" ]; then ptype="HTTPS"; else options="
			<Options>48</Options>"; fi
    [ "$LOCAL_DNS" = "1" ] && via="false"
    for d in $CLAUDE_DOMAINS; do dns="${dns:+$dns; }$d; *.$d"; done
    mkdir -p "$PX_PROFILE_DIR" || return 1
    cat > "$1" <<PROFILE_EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<!-- $MARKER $VERSION：由 xiaochuan-proxy.sh 生成，重新运行脚本会覆盖 -->
<ProxifierProfile version="101" platform="MacOSX" product_id="2" product_minver="200">
	<Options>
		<Resolve>
			<AutoModeDetection enabled="false" />
			<ViaProxy enabled="$via" />
			<ExclusionList OnlyFromListMode="true">$dns</ExclusionList>
		</Resolve>
		<Encryption mode="basic" />
		<HttpProxiesSupport enabled="false" />
		<HandleDirectConnections enabled="false" />
		<ConnectionLoopDetection enabled="true" />
		<ProcessServices enabled="false" />
		<ProcessOtherUsers enabled="false" />
	</Options>
	<ProxyList>
		<Proxy id="100" type="$ptype">$options
			<Port>$PX_PORT</Port>
			<Address>$PROXY_HOST</Address>
		</Proxy>
	</ProxyList>
	<ChainList />
	<RuleList>
		<Rule enabled="true">
			<Action type="Direct" />
			<Targets>localhost; 127.0.0.1; ::1; %ComputerName%</Targets>
			<Name>Localhost</Name>
		</Rule>
		<Rule enabled="true">
			<Action type="Proxy">100</Action>
			<Applications>$(proxifier_apps | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')</Applications>
			<Name>Claude via Clash</Name>
		</Rule>
		<Rule enabled="true">
			<Action type="Direct" />
			<Name>Default</Name>
		</Rule>
	</RuleList>
</ProxifierProfile>
PROFILE_EOF
}

install_proxifier() {
    local dmg="$DOWNLOAD_DIR/ProxifierMac.dmg"
    if [ -d "$PX_APP" ]; then
        log "Proxifier 已安装：$PX_APP"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）下载 $PROXIFIER_URL 并安装到 $PX_APP（同一个安装包同时支持 Apple 芯片和 Intel 芯片）"
        return 0
    fi
    log "正在下载 Proxifier：$PROXIFIER_URL"
    if ! download "$PROXIFIER_URL" "$dmg"; then
        fail "Proxifier 下载失败。请手动下载安装后重新运行：$PROXIFIER_URL"
        return 1
    fi
    if ! install_app_from_dmg "$dmg" "Proxifier.app"; then
        fail "Proxifier 安装失败（dmg 打不开，或没法写入 /Applications）。安装包在：$dmg"
        return 1
    fi
    # 只留下签名有效的程序，防止下载到被改过的文件。
    if ! codesign --verify --deep --strict "$PX_APP" >/dev/null 2>&1; then
        rm -rf "$PX_APP" 2>/dev/null || run_root rm -rf "$PX_APP"
        fail "下载到的 Proxifier 代码签名无效，已删除。请到 https://www.proxifier.com/download/ 手动下载。"
        return 1
    fi
    log "Proxifier 已安装（代码签名有效）：$PX_APP"
}

set_proxifier() {
    [ "$DO_PX" = "1" ] || return 0
    local f default="$PX_PROFILE_DIR/Default.ppx"
    if [ "$OS" != "mac" ]; then
        skip "Proxifier 没有 Linux 版，这一步已跳过；Linux 上靠「Claude Code 代理设置」让 Claude Code 只走代理。"
        return 0
    fi
    log "准备安装 / 配置 Proxifier…"
    install_proxifier || return 1
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）备份现有的 Proxifier 配置，写入 $PX_PROFILE 并让 Proxifier 载入："
        log "（演练）  代理服务器 $PROXY_HOST:$PX_PORT（$PX_TYPE）；规则：$(proxifier_apps) 走代理，其余直连"
        return 0
    fi
    # 修改前把现有的 Proxifier 配置全部备份。
    for f in "$PX_PROFILE_DIR"/*.ppx; do
        [ -f "$f" ] && backup_file "$f" "proxifier-profiles/$(basename "$f")"
    done
    if ! write_profile "$PX_PROFILE"; then
        fail "Proxifier 配置文件写入失败：$PX_PROFILE"
        return 1
    fi
    # 刚装好的 Proxifier 第一次启动会自动载入 Default.ppx；用户已有自己的 Default.ppx 时不动它。
    if [ ! -f "$default" ] || grep -q "$MARKER" "$default" 2>/dev/null; then
        cp "$PX_PROFILE" "$default" 2>/dev/null
    fi
    # 用 Proxifier 打开这个配置文件：没开就启动并载入，已经开着就载入到正在运行的 Proxifier。
    if ! open -a "$PX_APP" "$PX_PROFILE" >/dev/null 2>&1; then
        fail "Proxifier 启动失败；请手动打开 Proxifier，再用 File > Load Profile 载入 xiaochuan-claude。"
        return 1
    fi
    log "Proxifier 配置已写入并载入：$PX_PROFILE"
}

# ------------------------------------------------- 浏览器策略（Linux，可选）

# PAC 脚本：Claude 的网站只走 Clash 代理，没有 DIRECT 回退（代理不通就打不开）。
pac_text() {
    local proxy="" domains="" d other='return "DIRECT";'
    [ -n "$PX_SOCKS" ] && proxy="SOCKS5 $PROXY_HOST:$PX_SOCKS"
    [ -n "$PX_HTTP" ] && proxy="${proxy:+$proxy; }PROXY $PROXY_HOST:$PX_HTTP"
    for d in $CLAUDE_DOMAINS; do domains="${domains:+$domains, }\"$d\""; done
    [ "$BROWSER_MODE" = "all" ] && other='return P;'
    cat <<PAC_EOF
// $MARKER $VERSION mode=$BROWSER_MODE
function FindProxyForURL(url, host) {
  var P = "$proxy";
  var d = [$domains];
  host = host.toLowerCase();
  if (isPlainHostName(host) || host == "localhost" || host == "127.0.0.1" || host == "[::1]") return "DIRECT";
  for (var i = 0; i < d.length; i++) { if (host == d[i] || dnsDomainIs(host, "." + d[i])) return P; }
  if (/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)/.test(host)) return "DIRECT";
  $other
}
PAC_EOF
}

# 要写进策略文件的内容（一行 JSON）。
policy_json() {
    printf '{"ProxyMode":"pac_script","ProxyPacUrl":"data:application/x-ns-proxy-autoconfig;base64,%s","ProxyPacMandatory":true}\n' \
        "$(pac_text | base64 | tr -d '\n')"
}

# 这台电脑上装了哪些会读策略的浏览器，输出它们的策略目录（每行一个）。
browser_policy_dirs() {
    command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1 && echo /etc/opt/chrome/policies/managed
    command -v microsoft-edge >/dev/null 2>&1 || command -v microsoft-edge-stable >/dev/null 2>&1 && echo /etc/opt/edge/policies/managed
    command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 && echo /etc/chromium/policies/managed
    return 0
}

# 已经写了我们的策略文件的目录（用顿号隔开）；没有则输出空。
browser_policy_set() {
    local d out=""
    for d in $POLICY_DIRS; do
        [ -f "$d/$POLICY_NAME" ] && out="${out:+$out、}$d"
    done
    printf '%s' "$out"
}

set_browser() {
    [ "$DO_BROWSER" = "1" ] || return 0
    local dirs d what="Claude 的网站强制走代理，其余网站直连" tmp
    if [ "$OS" = "mac" ]; then
        skip "macOS 上浏览器的强制代理策略要靠 MDM（设备管理）下发，脚本做不了；已跳过。"
        return 0
    fi
    log "准备设置浏览器代理策略…"
    dirs="$(browser_policy_dirs)"
    if [ -z "$dirs" ]; then
        skip "没检测到 Chrome / Edge / Chromium，浏览器这一步已跳过。"
        return 0
    fi
    [ "$BROWSER_MODE" = "all" ] && what="所有网站强制走代理"
    if [ "$DRY_RUN" = "1" ]; then
        for d in $dirs; do log "（演练）写入 $d/$POLICY_NAME（$what）"; done
        return 0
    fi
    need_root || { fail "没有管理员权限，写不了浏览器策略文件。"; return 1; }
    tmp="$(mktemp "${TMPDIR:-/tmp}/xc-policy.XXXXXX")" || return 1
    policy_json > "$tmp"
    for d in $dirs; do
        if run_root mkdir -p "$d" && run_root install -m 644 "$tmp" "$d/$POLICY_NAME"; then
            log "已写入 $d/$POLICY_NAME（重新打开浏览器后生效）。"
        else
            fail "浏览器策略文件写入失败：$d/$POLICY_NAME"
        fi
    done
    rm -f "$tmp"
}

# ------------------------------------------------------------------- IPv6

# 只检查、不修改：方案要求不要未经测试就全局关闭 IPv6。输出 on / off。
ip6_state() {
    if [ "$OS" = "mac" ]; then
        if ifconfig 2>/dev/null | grep 'inet6 ' | grep -vqE 'inet6 (::1|fe80:)'; then echo on; else echo off; fi
        return 0
    fi
    if [ -d /proc/sys/net/ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "0" ]; then
        echo on
    else
        echo off
    fi
}

# ----------------------------------------------------------------- 主流程

# 状态里的一行：$1 是 ✓、✗ 或 -。
status_line() {
    case "$1" in
        "✓") printf '  %s✓ %s%s\n' "$C_OK" "$2" "$C_OFF" ;;
        "-") printf '  - %s\n' "$2" ;;
        *) printf '  %s✗ %s%s\n' "$C_BAD" "$2" "$C_OFF"; STATUS_BAD=$((STATUS_BAD + 1)) ;;
    esac
}

# 逐项显示当前状态（会真的通过代理连一次 Claude 的服务器）。
status() {
    local open pport cur set
    STATUS_BAD=0
    if find_proxy; then
        status_line "✓" "Clash 本地代理：$(proxy_text)，通过它能连上 Claude 的服务器"
    else
        open="$(any_candidate_open)"
        if [ -n "$open" ]; then
            status_line "✗" "Clash 本地代理：端口 $open 在监听，但通过它连不上 Claude 的服务器（节点不可用，或端口不对）"
        else
            status_line "✗" "Clash 本地代理：没找到在监听的代理端口（Clash 没开？或用 --proxy-port 指定端口）"
        fi
    fi

    cur="$(code_proxy_current)"
    if code_proxy_ok; then
        status_line "✓" "Claude Code 代理设置：$cur"
    elif [ -n "$cur" ]; then
        status_line "✗" "Claude Code 代理设置：现在是 $cur，和 Clash 的端口不一致（重新运行脚本即可）"
    else
        status_line "✗" "Claude Code 代理设置：还没有写入"
    fi

    if [ "$OS" = "mac" ]; then
        pport="$(profile_port)"
        if [ ! -d "$PX_APP" ]; then
            status_line "✗" "Proxifier：没有安装"
        elif ! proxifier_running; then
            status_line "✗" "Proxifier：已安装，但没有运行（没运行时 Claude Desktop 不会走代理）"
        elif [ -z "$pport" ]; then
            status_line "✗" "Proxifier：在运行，但还没有写入 Claude 规则"
        elif [ -n "$PX_PORT" ] && [ "$pport" != "$PX_PORT" ]; then
            status_line "✗" "Proxifier：规则里的代理端口是 $pport，和 Clash 现在的端口 $PX_PORT 不一致（重新运行脚本即可）"
        else
            status_line "✓" "Proxifier：在运行，Claude 规则已写入（代理端口 $pport）"
        fi
        status_line "-" "防火墙 Kill Switch：macOS 自带的防火墙不能按程序拦出站连接，脚本做不了（Proxifier 退出时 Claude Desktop 会直连）"
    else
        status_line "-" "Proxifier：没有 Linux 版（Linux 上也没有官方的 Claude Desktop）；Claude Code 靠上面的代理设置"
        set="$(browser_policy_set)"
        if [ -n "$set" ]; then
            status_line "-" "浏览器代理策略（可选项）：已设置：$set"
        else
            status_line "-" "浏览器代理策略（可选项）：没有设置"
        fi
    fi

    if [ "$(ip6_state)" = "on" ]; then
        status_line "-" "IPv6：系统开着 IPv6（脚本不去关它；需要关闭时用 xiaochuan-env 的「关闭系统 IPv6」）"
    else
        status_line "-" "IPv6：系统没有开 IPv6"
    fi
}

# 执行后逐项核对「选中的项目」有没有真的做到。
verify_results() {
    local want_code="$1" want_px="$2" want_browser="$3" pport d
    if [ "$want_code" = "1" ]; then
        if code_proxy_ok; then
            ok_item "Claude Code 代理设置：$(code_proxy_url)（重新打开 Claude Code 后生效）"
        else
            bad_item "Claude Code 代理设置：没有写进 settings.json"
        fi
    fi
    if [ "$want_px" = "1" ] && [ "$OS" = "mac" ]; then
        pport="$(profile_port)"
        if [ ! -d "$PX_APP" ]; then
            bad_item "Proxifier：没有安装上"
        elif [ "$pport" != "$PX_PORT" ]; then
            bad_item "Proxifier：Claude 规则没有写进配置文件"
        elif ! proxifier_running; then
            bad_item "Proxifier：配置已写好，但 Proxifier 没有运行起来；请手动打开 Proxifier"
        else
            ok_item "Proxifier：已运行，配置已写入（Claude 程序走 $PROXY_HOST:$pport，其他软件直连）"
        fi
    fi
    if [ "$want_browser" = "1" ] && [ "$OS" = "linux" ]; then
        for d in $(browser_policy_dirs); do
            if [ -f "$d/$POLICY_NAME" ] && [ "$(cat "$d/$POLICY_NAME" 2>/dev/null)" = "$(policy_json)" ]; then
                ok_item "浏览器代理策略：$d/$POLICY_NAME（重新打开浏览器后生效）"
            else
                bad_item "浏览器代理策略：没有写进 $d/$POLICY_NAME"
            fi
        done
    fi
}

run_pipeline() {
    if [ "$DO_CODE$DO_PX$DO_BROWSER" = "000" ]; then
        echo "请至少选择一个执行项目。"
        return 1
    fi
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$DATA_DIR/proxy-backups/$STAMP"
    [ "$DRY_RUN" = "1" ] && log "演练模式：只显示将要做的事，不做任何修改。"
    local want_code="$DO_CODE" want_px="$DO_PX" want_browser="$DO_BROWSER"

    # 每一步都要用 Clash 的本地代理入口；入口找不到或不通就不往下做，免得把 Claude 的网络弄断。
    init_proxy || return 1

    set_code_proxy
    set_proxifier
    set_browser

    if [ "$DRY_RUN" = "1" ]; then
        skip "演练结束，没有做任何修改。"
        return 0
    fi
    verify_results "$want_code" "$want_px" "$want_browser"
    if [ "$want_px" = "1" ] && [ "$OS" = "mac" ]; then
        info_item "需要你手动做：第一次打开 Proxifier 时，到 系统设置 > 通用 > 登录项与扩展 > 网络扩展 里允许 Proxifier（系统不允许脚本代点）"
        info_item "需要你手动做：Proxifier 是收费软件（31 天试用），到期后要自己购买并输入注册码；要开机自动启动的话，把它加到 系统设置 > 通用 > 登录项"
        info_item "需要你手动验证：在 Proxifier 窗口里确认 Claude 的连接显示为走代理；退出 Clash 后 Claude 应该连不上"
        info_item "做不了：macOS 自带的防火墙不能按程序拦出站连接，所以没有 Kill Switch——Proxifier 退出时 Claude Desktop 会直连（Claude Code 有自己的代理设置，不受影响）"
    fi
    [ -d "$BACKUP_DIR" ] && info_item "修改前的备份：$BACKUP_DIR"
    [ "$BAD_COUNT" = "0" ]
}

# 撤销本脚本做的所有修改。Proxifier / Clash 程序本身不卸载。
undo_all() {
    local f d left=""
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$DATA_DIR/proxy-backups/$STAMP"
    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）删除 Claude Code 代理设置、Proxifier 的 Claude 配置（并退出 Proxifier）、浏览器代理策略文件"
        skip "演练结束，没有做任何修改。"
        return 0
    fi
    if [ -f "$CLAUDE_SETTINGS" ]; then
        backup_file "$CLAUDE_SETTINGS" "claude/settings.json"
        if edit_settings unset && [ -z "$(code_proxy_current | grep -E '^http://127\.0\.0\.1:[0-9]+$')" ]; then
            ok_item "Claude Code 代理设置：已删除"
        else
            bad_item "Claude Code 代理设置：删除失败（文件：$CLAUDE_SETTINGS）"
        fi
    else
        ok_item "Claude Code 代理设置：本来就没有"
    fi

    if [ "$OS" = "mac" ]; then
        osascript -e 'tell application "Proxifier" to quit' >/dev/null 2>&1
        sleep 2
        proxifier_running && pkill -x Proxifier >/dev/null 2>&1
        for f in "$PX_PROFILE" "$PX_PROFILE_DIR/Default.ppx"; do
            [ -f "$f" ] && grep -q "$MARKER" "$f" 2>/dev/null || continue
            backup_file "$f" "proxifier-profiles/$(basename "$f")"
            rm -f "$f"
        done
        if [ -z "$(profile_port)" ] && ! proxifier_running; then
            ok_item "Proxifier：已退出，Claude 配置已删除"
        else
            bad_item "Proxifier：没能退出或配置没删掉，请手动退出 Proxifier"
        fi
        [ -d "$PX_APP" ] && info_item "Proxifier 程序本身没有卸载；需要的话把 /Applications/Proxifier.app 拖进废纸篓"
    else
        if [ -n "$(browser_policy_set)" ]; then
            need_root
            for d in $POLICY_DIRS; do
                [ -f "$d/$POLICY_NAME" ] && run_root rm -f "$d/$POLICY_NAME"
            done
        fi
        left="$(browser_policy_set)"
        if [ -z "$left" ]; then
            ok_item "浏览器代理策略：已删除"
        else
            bad_item "浏览器代理策略：没删掉：$left（需要管理员权限）"
        fi
    fi
    info_item "现在 Claude 恢复成原来的联网方式（不再强制走代理）"
    [ "$BAD_COUNT" = "0" ]
}

menu() {
    local c picked bad undo choices
    while :; do
        DO_CODE=0; DO_PX=0; DO_BROWSER=0
        ERRORS=0; RESULTS=""; OK_COUNT=0; BAD_COUNT=0
        picked=0; bad=0; undo=0

        echo
        echo "================ 小川强制代理助手 $VERSION（$OS）================"
        status
        echo
        echo "  1) Claude Code：写入自身代理设置（代理不通就连接失败）"
        if [ "$OS" = "mac" ]; then
            echo "  2) Proxifier：下载安装，写入「Claude 走 Clash 代理、其他软件直连」的规则"
            echo "  a) 一键执行 1 2（推荐）"
        else
            echo "  3) 浏览器（可选）：Chrome / Edge / Chromium 里 Claude 的网站强制走代理"
            echo "  a) 一键执行 1（推荐）"
        fi
        echo "  u) 撤销本脚本做的全部修改"
        echo "  q) 退出"
        echo
        printf '请输入要执行的项目（可多选，用空格分开），然后按回车：'
        read -r choices || exit 0

        # 允许用逗号分隔；关掉通配符展开，免得输入 * 之类被当成文件名。
        set -f
        # shellcheck disable=SC2086
        set -- $(printf '%s' "$choices" | tr ',' ' ')
        set +f
        for c in "$@"; do
            case "$c" in
                1) DO_CODE=1; picked=1 ;;
                2) if [ "$OS" = "mac" ]; then DO_PX=1; picked=1; else echo "这个系统没有选项 2"; bad=1; break; fi ;;
                3) if [ "$OS" = "linux" ]; then DO_BROWSER=1; picked=1; else echo "这个系统没有选项 3"; bad=1; break; fi ;;
                a|A) DO_CODE=1; [ "$OS" = "mac" ] && DO_PX=1; picked=1 ;;
                u|U) undo=1; picked=1 ;;
                q|Q) exit 0 ;;
                *) echo "看不懂的选项：$c"; bad=1; break ;;
            esac
        done

        if [ "$bad" = "0" ]; then
            [ "$picked" = "1" ] || continue
            if [ "$undo" = "1" ]; then undo_all; else run_pipeline; fi
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
小川强制代理助手 $VERSION（macOS / Linux）
让 Claude Code（macOS 上还有 Claude Desktop）只走 Clash 本地代理；代理失效时连接失败，不会自动直连。

用法：
  bash $0                  交互菜单（不带参数）
  bash $0 --all            直接执行：Claude Code 代理设置（macOS 再加 Proxifier）
  bash $0 --all --dry-run  演练，只显示将要做的事
  bash $0 status           检查当前状态（会真的通过代理连一次 Claude 服务器）
  bash $0 undo             撤销本脚本做的全部修改

选项：
  --claude-code        在 Claude Code 的 settings.json 里写入 HTTPS_PROXY / HTTP_PROXY
  --proxifier          仅 macOS：下载安装 Proxifier，写入 Claude 专用规则并载入
  --browser            仅 Linux、可选：Chrome / Edge / Chromium 用策略固定代理（不包含在 --all 里）
  --all                等于 --claude-code --proxifier
  --proxy-port 端口    指定 Clash 本地代理端口（默认自动查找）
  --proxy-type 类型    socks5 或 http（默认自动判断，优先 socks5）
  --browser-mode 模式  claude：只有 Claude 的网站走代理，其余直连（默认）；all：所有网站都走代理
  --local-dns          Proxifier 里 Claude 的域名改用本机 DNS 解析（默认通过代理解析，防止 DNS 泄漏）
  --dry-run            演练：只显示将要做的事，不做任何修改
  -h, --help           显示本说明

不要在前面加 sudo：脚本会在需要时自己申请管理员权限。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --claude-code) DO_CODE=1 ;;
        --proxifier) DO_PX=1 ;;
        --browser) DO_BROWSER=1 ;;
        --all) DO_CODE=1; DO_PX=1 ;;
        --proxy-port)
            shift
            case "${1:-}" in
                ''|*[!0-9]*) echo "--proxy-port 后面要跟端口号" >&2; exit 2 ;;
            esac
            OPT_PORT="$1" ;;
        --proxy-type)
            shift
            case "${1:-}" in
                socks5|http) OPT_TYPE="$1" ;;
                *) echo "--proxy-type 只能是 socks5 或 http" >&2; exit 2 ;;
            esac ;;
        --browser-mode)
            shift
            case "${1:-}" in
                claude|all) BROWSER_MODE="$1" ;;
                *) echo "--browser-mode 只能是 claude 或 all" >&2; exit 2 ;;
            esac ;;
        --local-dns) LOCAL_DNS=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        status|undo) ACTION="$1" ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

case "$ACTION" in
    status)
        echo "小川强制代理助手 $VERSION（$OS）"
        status
        echo "=========================================="
        if [ "$STATUS_BAD" = "0" ]; then
            printf '%s 结果：强制代理的各项设置都在 %s\n' "$C_OK_BAR" "$C_OFF"
        else
            printf '%s 结果：有 %s 项没有到位（上面标 ✗ 的红色行） %s\n' "$C_BAD_BAR" "$STATUS_BAD" "$C_OFF"
        fi
        [ "$STATUS_BAD" = "0" ]
        exit $?
        ;;
    undo)
        undo_all
        ;;
    "")
        if [ "$DO_CODE$DO_PX$DO_BROWSER" != "000" ]; then
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
