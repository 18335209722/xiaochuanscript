#!/usr/bin/env bash
# 小川重启后助手 · macOS / Linux 版
# 重启电脑之后执行，一次做两件事：
#   1. Chrome：新建一个「不登录 Google 账号」的个人资料（默认名字 claude），并用它打开 Chrome。
#      已经建过就直接打开。不动用户原来登录过的那个个人资料，只是不再用它。
#   2. Clash Verge Rev（https://github.com/clash-verge-rev/clash-verge-rev）：
#      已经装了就不再安装；没有装就找到适合本机的最新版，下载、校验、安装，然后打开。
# 执行过程中会显示现在做到第几步，下载时显示下载进度，最后打印「执行结果」。
# 兼容 macOS 自带的 bash 3.2。不要加 sudo，需要管理员权限时脚本会自己申请。

VERSION="1.0.0"
PROFILE_NAME="claude"
REPO="clash-verge-rev/clash-verge-rev"
RELEASES_PAGE="https://github.com/$REPO/releases/latest"
# GitHub 直连下载失败或太慢时用的镜像。镜像不是官方的，所以只有在拿到官方校验值
# 并且下载下来的文件校验一致时才会使用。
MIRRORS="https://gh-proxy.com/ https://ghfast.top/"
# 下载速度连续 20 秒低于这个值（字节/秒）就换下一个下载地址。
MIN_SPEED=100000

DRY_RUN=0
DO_CHROME=1
DO_CLASH=1
ERRORS=0
TMP_DIR=""
STEP_NO=0
TOTAL_STEPS=0

case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux) OS="linux" ;;
    *) echo "只支持 macOS 和 Linux。" >&2; exit 1 ;;
esac

# 用 sudo 整个运行的话，Chrome 个人资料会建到 root 名下、Clash Verge 以 root 身份启动，所以退回原用户。
if [ "$(id -u)" = "0" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -f "$0" ]; then
        echo "检测到用 sudo 运行：改回用户 $SUDO_USER 的身份执行，需要管理员权限的步骤会自动提权。"
        exec sudo -u "$SUDO_USER" -H -- bash "$0" "$@"
    fi
    echo "不要用 root 运行：Chrome 的个人资料和 Clash Verge 都属于当前登录的用户。" >&2
    exit 1
fi

DATA_DIR="$HOME/.xiaochuan-env"
if [ "$OS" = "mac" ]; then
    CHROME_DATA="$HOME/Library/Application Support/Google/Chrome"
else
    CHROME_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome"
fi

# ---------------------------------------------------------------- 结果汇总
# 脚本结束前会打印一份「执行结果」：完成的标绿色 ✓，没有完成的标红色 ✗，
# 最后一行用整条绿底 / 红底显示总结果。颜色只在终端里用，输出被重定向到文件时不带颜色码。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_OK_BAR=$'\033[1;97;42m'; C_BAD_BAR=$'\033[1;97;41m'
    C_DIM_BAR=$'\033[1;30;47m'; C_STEP=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_BAD=""; C_OK_BAR=""; C_BAD_BAR=""; C_DIM_BAR=""; C_STEP=""; C_OFF=""
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
# 显示现在做到第几步：step "查找最新版"
step() {
    STEP_NO=$((STEP_NO + 1))
    printf '\n%s==== 第 %s/%s 步：%s ====%s\n' "$C_STEP" "$STEP_NO" "$TOTAL_STEPS" "$1" "$C_OFF"
}

usage() {
    cat <<EOF
小川重启后助手 $VERSION（macOS / Linux）

重启电脑之后执行，一次做两件事：
  1. 新建一个不登录 Google 账号的 Chrome 个人资料并用它打开 Chrome；已经建过就直接打开。
  2. 检查有没有装 Clash Verge Rev；没装就下载适合本机的最新版，安装并打开。

用法：
  bash $0                  两件事都做
  bash $0 --name 名字      Chrome 个人资料换一个名字（默认 claude）
  bash $0 --only-chrome    只做 Chrome 个人资料
  bash $0 --only-clash     只做 Clash Verge
  bash $0 --dry-run        演练：只显示将要做的事，不做任何修改
  bash $0 --help           显示本说明
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name)
            [ $# -ge 2 ] || { echo "--name 后面要跟名字" >&2; exit 2; }
            shift
            PROFILE_NAME="$1" ;;
        --only-chrome) DO_CHROME=1; DO_CLASH=0 ;;
        --only-clash) DO_CHROME=0; DO_CLASH=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

run_root() {
    if [ "$(id -u)" = "0" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ================================================================ Chrome 个人资料

chrome_installed() {
    if [ "$OS" = "mac" ]; then
        [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]
    else
        command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1
    fi
}

# 用指定的个人资料目录打开 Chrome。$1：目录名，例如 Profile 3
launch_chrome() {
    local bin
    if [ "$OS" = "mac" ]; then
        open -na "Google Chrome" --args --profile-directory="$1" --no-first-run --no-default-browser-check
    else
        bin="$(command -v google-chrome 2>/dev/null || command -v google-chrome-stable 2>/dev/null)"
        [ -n "$bin" ] || return 1
        nohup "$bin" --profile-directory="$1" --no-first-run --no-default-browser-check >/dev/null 2>&1 &
    fi
}

# Chrome 是否已经把这个个人资料登记进 Local State。$1：目录名
registered() {
    grep -q "\"$1\"" "$CHROME_DATA/Local State" 2>/dev/null
}

chrome_profile() {
    local name="$PROFILE_NAME" record dir="" n=1 i=0 bs='\'
    step "Chrome：新建 / 打开不登录账号的个人资料「$name」"
    case "$name" in
        ""|*'"'*|*"$bs"*) fail "Chrome 个人资料名字不能为空，也不能包含引号或反斜杠。"; return 1 ;;
    esac
    if ! chrome_installed; then
        fail "没有找到 Google Chrome，请先安装。"
        return 1
    fi

    # 记下这个名字对应哪个目录，下次执行就直接打开，不会重复新建。
    record="$DATA_DIR/chrome-profile-$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '_')"
    if [ -f "$record" ]; then
        dir="$(cat "$record")"
        if [ -z "$dir" ] || [ ! -d "$CHROME_DATA/$dir" ]; then
            dir=""
        fi
    fi

    if [ -n "$dir" ]; then
        log "个人资料「$name」已经建过（$dir），直接打开。"
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）用个人资料「$name」（$dir）打开 Chrome"
            info_item "Chrome 演练：会用已有的个人资料「$name」（$dir）打开 Chrome，没有做任何修改"
            return 0
        fi
    else
        while [ -e "$CHROME_DATA/Profile $n" ]; do
            n=$((n + 1))
        done
        dir="Profile $n"
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）新建 Chrome 个人资料「$name」（目录 $dir，不登录账号，语言只有英文），并用它打开 Chrome"
            info_item "Chrome 演练：会新建个人资料「$name」（$dir）并打开 Chrome，没有做任何修改"
            return 0
        fi
        # 提前写好这份配置，Chrome 第一次用这个目录时就会按它建个人资料：
        # 名字是指定的名字，不登录任何账号，语言只有英文，定位默认关闭（geolocation 2 = 禁止）。
        if ! mkdir -p "$CHROME_DATA/$dir" || ! printf '%s' "{\"profile\":{\"name\":\"$name\",\"using_default_name\":false,\"default_content_setting_values\":{\"geolocation\":2}},\"intl\":{\"accept_languages\":\"en-US,en\",\"selected_languages\":\"en-US,en\"},\"spellcheck\":{\"dictionaries\":[\"en-US\"]},\"translate_blocked_languages\":[\"en\"],\"translate_recent_target\":\"en\"}" > "$CHROME_DATA/$dir/Preferences"; then
            fail "创建 Chrome 个人资料目录失败：$CHROME_DATA/$dir"
            return 1
        fi
        mkdir -p "$DATA_DIR" && printf '%s\n' "$dir" > "$record"
        log "已新建个人资料「$name」（$dir），未登录任何账号。"
    fi

    log "正在用个人资料「$name」打开 Chrome…"
    if ! launch_chrome "$dir"; then
        fail "Chrome 启动失败。"
        return 1
    fi

    # 核对：Chrome 把这个个人资料登记进 Local State，并且名字是对的，才算成功。
    while [ "$i" -lt 20 ] && ! registered "$dir"; do
        sleep 1
        i=$((i + 1))
    done
    if ! registered "$dir"; then
        bad_item "Chrome 没有登记个人资料 $dir（可能没有成功启动）"
        return 1
    fi
    if grep -q "\"$dir\":{[^}]*\"name\":\"$name\"" "$CHROME_DATA/Local State" 2>/dev/null \
        || grep -q "\"name\":\"$name\"" "$CHROME_DATA/$dir/Preferences" 2>/dev/null; then
        ok_item "Chrome 已用个人资料「$name」（$dir）打开，未登录账号"
    else
        bad_item "Chrome 个人资料 $dir 已打开，但名字不是「$name」；可在 Chrome 右上角头像 > 齿轮 里手动改名"
        return 1
    fi
    log "以后直接点 Chrome 图标，默认也会进入这个个人资料（Chrome 会记住最后使用的那个）。"
}

# ================================================================ Clash Verge

# ---------------------------------------------------------------- 检测

mac_app_path() {
    local p
    for p in "/Applications/Clash Verge.app" "$HOME/Applications/Clash Verge.app"; do
        if [ -d "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

clash_installed() {
    if [ "$OS" = "mac" ]; then
        mac_app_path >/dev/null
    else
        command -v clash-verge >/dev/null 2>&1 && return 0
        [ -x /usr/bin/clash-verge ] && return 0
        dpkg -s clash-verge >/dev/null 2>&1 && return 0
        rpm -q clash-verge >/dev/null 2>&1 && return 0
        return 1
    fi
}

clash_running() {
    if [ "$OS" = "mac" ]; then
        pgrep -f "Clash Verge.app/Contents/MacOS/" >/dev/null 2>&1
    else
        pgrep -x clash-verge >/dev/null 2>&1
    fi
}

# 本机该用哪个安装包：输出文件名的结尾部分。
asset_suffix() {
    local arch
    arch="$(uname -m)"
    if [ "$OS" = "mac" ]; then
        # Apple 芯片的 Mac 在 Rosetta 终端里 uname -m 会报 x86_64，所以再问一次硬件。
        if [ "$arch" = "arm64" ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
            echo "_aarch64.dmg"
        else
            echo "_x64.dmg"
        fi
        return 0
    fi
    case "$arch" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) return 1 ;;
    esac
    if command -v dpkg >/dev/null 2>&1; then
        if [ "$arch" = "x64" ]; then echo "_amd64.deb"; else echo "_arm64.deb"; fi
    elif command -v rpm >/dev/null 2>&1; then
        if [ "$arch" = "x64" ]; then echo ".x86_64.rpm"; else echo ".aarch64.rpm"; fi
    else
        return 1
    fi
}

# ---------------------------------------------------------------- 找最新版

# 读 GitHub 的发布信息（标准输入），输出：第一行 TAG<TAB>版本号，之后每行 文件名<TAB>下载地址<TAB>sha256<TAB>大小（字节）。
parse_release() {
    if command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1; then
        perl -MJSON::PP -e '
            local $/;
            my $d = decode_json(<STDIN>);
            print "TAG\t$d->{tag_name}\n";
            for my $a (@{ $d->{assets} || [] }) {
                my $g = $a->{digest} // "";
                $g =~ s/^sha256://;
                my $s = $a->{size} // "";
                print "$a->{name}\t$a->{browser_download_url}\t$g\t$s\n";
            }'
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
d = json.load(sys.stdin)
print("TAG\t" + d["tag_name"])
for a in d.get("assets", []):
    g = a.get("digest") or ""
    if g.startswith("sha256:"):
        g = g[7:]
    print(a["name"] + "\t" + a["browser_download_url"] + "\t" + g + "\t" + str(a.get("size") or ""))'
    else
        return 1
    fi
}

# 找到本机要下载的安装包，结果放进 ASSET_NAME / ASSET_URL / ASSET_SHA / ASSET_SIZE / RELEASE_TAG。
# 先问 GitHub 接口（能拿到校验值）；接口不通就从「最新版」页面的跳转地址里取版本号，自己拼文件名。
find_asset() {
    local suffix="$1" list line tag ver final
    ASSET_NAME=""; ASSET_URL=""; ASSET_SHA=""; ASSET_SIZE=""; RELEASE_TAG=""

    list="$(curl -fsSL --connect-timeout 15 -m 40 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | parse_release 2>/dev/null)"
    if [ -n "$list" ]; then
        RELEASE_TAG="$(printf '%s\n' "$list" | awk -F '\t' '$1 == "TAG" { print $2; exit }')"
        line="$(printf '%s\n' "$list" | awk -F '\t' -v s="$suffix" '
            $1 != "TAG" && length($1) >= length(s) && substr($1, length($1) - length(s) + 1) == s { print; exit }')"
        if [ -n "$line" ]; then
            ASSET_NAME="$(printf '%s' "$line" | cut -f1)"
            ASSET_URL="$(printf '%s' "$line" | cut -f2)"
            ASSET_SHA="$(printf '%s' "$line" | cut -f3)"
            ASSET_SIZE="$(printf '%s' "$line" | cut -f4)"
            return 0
        fi
    fi

    final="$(curl -fsSLI --connect-timeout 15 -m 40 -o /dev/null -w '%{url_effective}' "$RELEASES_PAGE" 2>/dev/null)"
    tag="${final##*/tag/}"
    case "$tag" in
        v[0-9]*) ;;
        *) return 1 ;;
    esac
    ver="${tag#v}"
    RELEASE_TAG="$tag"
    case "$suffix" in
        *.rpm) ASSET_NAME="Clash.Verge-$ver-1$suffix" ;;
        *) ASSET_NAME="Clash.Verge_$ver$suffix" ;;
    esac
    ASSET_URL="https://github.com/$REPO/releases/download/$tag/$ASSET_NAME"
    return 0
}

# 安装包大小的文字说明，例如「（约 45 MB）」；不知道大小就是空的。
size_text() {
    case "${ASSET_SIZE:-}" in
        ''|*[!0-9]*) return 0 ;;
    esac
    printf '（约 %s MB）' "$(( (ASSET_SIZE + 524288) / 1048576 ))"
}

# ---------------------------------------------------------------- 下载

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# 文件校验值是否和官方的一致；没有官方校验值时返回 2。
checksum_ok() {
    [ -n "$ASSET_SHA" ] || return 2
    [ "$(sha256_of "$1")" = "$ASSET_SHA" ]
}

# $1 下载地址  $2 保存位置  $3 最低速度（字节/秒，0 = 不限）
# 下载时屏幕上会显示进度条和百分比。连续 20 秒低于最低速度就放弃，好换下一个下载地址。
fetch() {
    if [ "${3:-0}" -gt 0 ]; then
        curl -fL --connect-timeout 20 --retry 2 --speed-limit "$3" --speed-time 20 --progress-bar -o "$2" "$1"
    else
        # 不限速度的兜底下载：多重试几次，断了自动续传。
        curl -fL --connect-timeout 30 --retry 5 --retry-delay 3 -C - --progress-bar -o "$2" "$1"
    fi
}

# 从一个地址下载并校验。$1 地址  $2 保存位置  $3 最低速度  $4 为 1 表示必须校验通过才算数（镜像）
try_source() {
    local rc
    if fetch "$1" "$2" "$3"; then
        checksum_ok "$2"; rc=$?
        if [ "$rc" = "0" ]; then
            log "下载完成，校验值和官方一致。"
            return 0
        elif [ "$rc" = "2" ] && [ "$4" != "1" ]; then
            warn "下载完成，但没拿到官方校验值，无法校验（文件来自 GitHub 官方地址）。"
            return 0
        fi
        warn "下载的文件校验值和官方不一致，已丢弃。"
    else
        warn "这个下载地址连不上或者太慢。"
    fi
    rm -f "$2"
    return 1
}

# 下载安装包到 $1：先 GitHub 直连；太慢或失败就换镜像；镜像也不行就回到直连、不限速度下完。
# 能校验的一律校验。
download_asset() {
    local out="$1" m
    log "正在从 GitHub 下载 $ASSET_NAME$(size_text) …"
    try_source "$ASSET_URL" "$out" "$MIN_SPEED" 0 && return 0

    if [ -n "$ASSET_SHA" ]; then
        for m in $MIRRORS; do
            log "换镜像下载：$m"
            try_source "$m$ASSET_URL" "$out" "$MIN_SPEED" 1 && return 0
        done
    else
        warn "没有官方校验值，不使用镜像（无法确认文件没被改过）。"
    fi

    log "回到 GitHub 直连再试一次，这次不限速度，慢也会下完，请耐心等待…"
    try_source "$ASSET_URL" "$out" 0 0
}

# ---------------------------------------------------------------- 安装 / 打开

install_mac() {
    local dmg="$1" mnt="$TMP_DIR/mnt" app
    mkdir -p "$mnt" || return 1
    if ! hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null; then
        fail "打不开安装包（dmg 挂载失败）。"
        return 1
    fi
    app="$(ls -d "$mnt"/*.app 2>/dev/null | head -n 1)"
    if [ -z "$app" ]; then
        hdiutil detach "$mnt" -quiet >/dev/null 2>&1
        fail "安装包里没有找到应用。"
        return 1
    fi
    log "正在把 $(basename "$app") 复制到「应用程序」…"
    # 普通方式复制不进去（当前用户不是管理员组）就用管理员权限再试。
    if ! ditto "$app" "/Applications/$(basename "$app")" 2>/dev/null; then
        run_root ditto "$app" "/Applications/$(basename "$app")"
    fi
    hdiutil detach "$mnt" -quiet >/dev/null 2>&1
    # 去掉「来自互联网」的隔离标记，免得第一次打开被拦或提示已损坏。
    xattr -dr com.apple.quarantine "/Applications/$(basename "$app")" >/dev/null 2>&1
    clash_installed
}

install_linux() {
    local pkg="$1"
    log "安装需要管理员权限，请输入本机登录密码（输入时屏幕上不显示，输完按回车）。"
    case "$pkg" in
        *.deb)
            if command -v apt-get >/dev/null 2>&1; then
                run_root apt-get install -y "$pkg" && return 0
            fi
            # apt 不行就用 dpkg 装，再让 apt 补齐依赖。
            run_root dpkg -i "$pkg" || run_root apt-get install -f -y
            ;;
        *.rpm)
            if command -v dnf >/dev/null 2>&1; then
                run_root dnf install -y "$pkg"
            elif command -v yum >/dev/null 2>&1; then
                run_root yum install -y "$pkg"
            elif command -v zypper >/dev/null 2>&1; then
                run_root zypper --non-interactive install --allow-unsigned-rpm "$pkg"
            else
                run_root rpm -i "$pkg"
            fi
            ;;
    esac
    clash_installed
}

open_clash() {
    if [ "$OS" = "mac" ]; then
        open -a "$(mac_app_path)"
    else
        nohup clash-verge >/dev/null 2>&1 &
    fi
}

clash_verge() {
    local suffix out i=0

    step "Clash Verge：检查有没有装"
    if clash_installed; then
        log "这台电脑已经装了 Clash Verge，不需要再安装，后面的步骤跳过。"
        ok_item "Clash Verge 已经安装，不需要再安装"
        return 0
    fi
    log "这台电脑还没有装 Clash Verge。"

    step "Clash Verge：查找适合本机的最新版"
    if ! command -v curl >/dev/null 2>&1; then
        fail "安装 Clash Verge 需要 curl。"
        return 1
    fi
    if ! suffix="$(asset_suffix)"; then
        fail "认不出这台电脑该用哪种 Clash Verge 安装包（$(uname -m)）。请到 $RELEASES_PAGE 手动下载。"
        return 1
    fi
    if ! find_asset "$suffix"; then
        fail "连不上 GitHub，查不到 Clash Verge 最新版。请检查网络，或到 $RELEASES_PAGE 手动下载。"
        return 1
    fi
    log "最新版是 $RELEASE_TAG，适合本机的安装包：$ASSET_NAME$(size_text)"

    if [ "$DRY_RUN" = "1" ]; then
        log "（演练）下载 $ASSET_URL"
        log "（演练）校验后安装，并打开 Clash Verge"
        info_item "Clash Verge 演练：会下载并安装 $ASSET_NAME，没有下载也没有安装"
        return 0
    fi

    step "Clash Verge：下载安装包（下面会显示下载进度）"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xc-clash.XXXXXX")" || { fail "建临时目录失败。"; return 1; }
    out="$TMP_DIR/$ASSET_NAME"
    if ! download_asset "$out"; then
        fail "Clash Verge 安装包下载失败。请检查网络，或到 $RELEASES_PAGE 手动下载 $ASSET_NAME。"
        return 1
    fi

    step "Clash Verge：安装"
    if [ "$OS" = "mac" ]; then
        install_mac "$out"
    else
        install_linux "$out"
    fi
    if ! clash_installed; then
        fail "Clash Verge 安装没有成功。"
        return 1
    fi
    log "安装完成。"
    ok_item "Clash Verge $RELEASE_TAG 已安装"

    step "Clash Verge：打开并检查"
    open_clash
    while [ "$i" -lt 20 ] && ! clash_running; do
        sleep 1
        i=$((i + 1))
    done
    if clash_running; then
        ok_item "Clash Verge 已打开"
    else
        bad_item "Clash Verge 没有成功打开，请手动打开一次"
    fi
    if [ "$OS" = "mac" ]; then
        log "提示：第一次打开时 Clash Verge 可能会要求输入密码来安装它的系统服务，按提示操作即可。"
    fi
}

# ================================================================ 主流程
# 两件事互不影响：前一件没成功，后一件照样做，最后在「执行结果」里一起列出来。

[ "$DO_CHROME" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$DO_CLASH" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 5))
[ "$DRY_RUN" = "1" ] && log "演练模式：只显示将要做的事，不做任何修改。"

[ "$DO_CHROME" = "1" ] && chrome_profile
[ "$DO_CLASH" = "1" ] && clash_verge

print_result
[ "$BAD_COUNT" = "0" ]
