#!/usr/bin/env bash
# 小川 Chrome 个人资料助手 · macOS / Linux 版
# 新建一个「不登录 Google 账号」的 Chrome 个人资料（默认名字 claude），并用它打开 Chrome。
# 已经建过就直接打开。不动用户原来登录过的那个个人资料，只是不再用它。
# 建议在重启电脑之后执行。不需要管理员权限，不要加 sudo。
# 兼容 macOS 自带的 bash 3.2。

VERSION="1.0.0"
PROFILE_NAME="claude"
DRY_RUN=0

case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux) OS="linux" ;;
    *) echo "只支持 macOS 和 Linux。" >&2; exit 1 ;;
esac

if [ "$(id -u)" = "0" ]; then
    echo "不要用 sudo / root 运行：Chrome 的个人资料属于当前登录的用户。" >&2
    exit 1
fi

DATA_DIR="$HOME/.xiaochuan-env"
if [ "$OS" = "mac" ]; then
    CHROME_DATA="$HOME/Library/Application Support/Google/Chrome"
else
    CHROME_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome"
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[%s] 失败：%s\n' "$(date +%H:%M:%S)" "$*" >&2; }

usage() {
    cat <<EOF
小川 Chrome 个人资料助手 $VERSION（macOS / Linux）

新建一个不登录 Google 账号的 Chrome 个人资料并用它打开 Chrome；已经建过就直接打开。

用法：
  bash $0                  新建 / 打开名字叫 claude 的个人资料
  bash $0 --name 名字      换一个名字
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
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

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

main() {
    local name="$PROFILE_NAME" record dir="" n=1 i=0 bs='\'
    case "$name" in
        ""|*'"'*|*"$bs"*) fail "个人资料名字不能为空，也不能包含引号或反斜杠。"; return 1 ;;
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
            return 0
        fi
    else
        while [ -e "$CHROME_DATA/Profile $n" ]; do
            n=$((n + 1))
        done
        dir="Profile $n"
        if [ "$DRY_RUN" = "1" ]; then
            log "（演练）新建 Chrome 个人资料「$name」（目录 $dir，不登录账号，语言只有英文），并用它打开 Chrome"
            return 0
        fi
        # 提前写好这份配置，Chrome 第一次用这个目录时就会按它建个人资料：
        # 名字是指定的名字，不登录任何账号，语言只有英文。
        if ! mkdir -p "$CHROME_DATA/$dir" || ! printf '%s' "{\"profile\":{\"name\":\"$name\",\"using_default_name\":false},\"intl\":{\"accept_languages\":\"en-US,en\",\"selected_languages\":\"en-US,en\"},\"spellcheck\":{\"dictionaries\":[\"en-US\"]},\"translate_blocked_languages\":[\"en\"],\"translate_recent_target\":\"en\"}" > "$CHROME_DATA/$dir/Preferences"; then
            fail "创建个人资料目录失败：$CHROME_DATA/$dir"
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
    echo
    echo "执行后检查："
    if ! registered "$dir"; then
        echo "  ✗ Chrome 没有登记个人资料 $dir（可能没有成功启动）"
        return 1
    fi
    if grep -q "\"$dir\":{[^}]*\"name\":\"$name\"" "$CHROME_DATA/Local State" 2>/dev/null \
        || grep -q "\"name\":\"$name\"" "$CHROME_DATA/$dir/Preferences" 2>/dev/null; then
        echo "  ✓ Chrome 已用个人资料「$name」（$dir）打开，未登录账号"
    else
        echo "  ✗ 个人资料 $dir 已打开，但名字不是「$name」；可在 Chrome 右上角头像 > 齿轮 里手动改名"
        return 1
    fi
    log "以后直接点 Chrome 图标，默认也会进入这个个人资料（Chrome 会记住最后使用的那个）。"
}

main
