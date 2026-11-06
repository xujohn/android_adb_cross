#!/usr/bin/env bash
#
# install-vscode.sh
#
# 安装最新稳定版 Visual Studio Code（官方 .deb 包）。
#
# 特点：
#   - 自动查询微软官方 API 获取最新稳定版版本号。
#   - 官方 CDN 域名（vscode.download.prss.microsoft.com）被污染时，
#     自动改用 Microsoft 软件源下载同一个包。
#   - 直连失败时自动走代理（默认 192.168.2.96:7897）。
#   - 安装包保存在 /home/jmc/dl/vscode，不删除，可重复使用。
#
# 用法：
#   bash install-vscode.sh
#   bash install-vscode.sh --proxy http://192.168.2.96:7897 --dl-dir /home/jmc/dl
#
set -Eeuo pipefail

PROXY="${PROXY:-http://192.168.2.96:7897}"
DL_DIR="${DL_DIR:-/home/jmc/dl}"
VSCODE_DIR="$DL_DIR/vscode"
LOG_DIR="$DL_DIR/logs"

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --proxy <url>     代理地址（默认: $PROXY）
  --dl-dir <dir>    下载目录（默认: $DL_DIR）
  -h, --help        显示帮助

示例:
  $(basename "$0")
  $(basename "$0") --proxy http://192.168.2.96:7897 --dl-dir /home/jmc/dl
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy)   PROXY="$2"; shift 2 ;;
        --proxy=*) PROXY="${1#*=}"; shift ;;
        --dl-dir)  DL_DIR="$2"; shift 2 ;;
        --dl-dir=*) DL_DIR="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
done

VSCODE_DIR="$DL_DIR/vscode"
LOG_DIR="$DL_DIR/logs"
mkdir -p "$DL_DIR" "$VSCODE_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-vscode-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[警告] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[错误] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'die "脚本在第 $LINENO 行执行失败（退出码 $?）"' ERR

SUDO=""
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "需要 root 权限，但系统没有 sudo"
    SUDO="sudo"
    $SUDO -n true 2>/dev/null || warn "sudo 可能需要输入密码"
fi

log "安装最新稳定版 Visual Studio Code"
info "下载目录：$DL_DIR"
info "日志文件：$LOG_FILE"

# ---------------------------------------------------------------------------
# 网络工具
# ---------------------------------------------------------------------------
fetch() {
    local url="$1" dest="$2" mode="${3:-auto}" part
    if [[ -s "$dest" ]]; then
        info "已存在，跳过下载：$dest"
        return 0
    fi
    part="${dest}.part"
    mkdir -p "$(dirname "$dest")"
    local -a args=(-fL --retry 4 --retry-delay 3 --connect-timeout 15 -C - -o "$part")

    if [[ "$mode" == "proxy" ]]; then
        info "通过代理下载：$url"
        curl "${args[@]}" -x "$PROXY" "$url" || { warn "代理下载失败：$url"; return 1; }
    else
        info "下载：$url"
        if ! curl "${args[@]}" "$url"; then
            warn "直连失败，改用代理重试：$url"
            curl "${args[@]}" -x "$PROXY" "$url" || { warn "下载失败：$url"; return 1; }
        fi
    fi
    mv -f "$part" "$dest"
}

verify_sha256() {
    local file="$1" want="$2" got
    [[ -z "$want" ]] && return 0
    got="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$got" != "$want" ]]; then
        warn "SHA256 校验失败：$file（期望 $want，实际 $got）"
        return 1
    fi
    info "SHA256 校验通过：$(basename "$file")"
}

# ---------------------------------------------------------------------------
# 修复可能被中断的 dpkg 状态
# ---------------------------------------------------------------------------
if [[ -n "$($SUDO dpkg --audit 2>/dev/null || true)" ]]; then
    warn "检测到 dpkg 有未完成的配置，尝试以非交互方式修复"
    echo "lightdm shared/default-x-display-manager select lightdm" \
        | $SUDO debconf-set-selections 2>/dev/null || true
    $SUDO env DEBIAN_FRONTEND=noninteractive dpkg --configure -a || \
        warn "dpkg --configure -a 仍有失败项，继续尝试安装"
fi

$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq || \
    warn "apt-get update 失败，继续使用现有索引"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates python3 || warn "基础依赖安装失败"

# ---------------------------------------------------------------------------
# 获取最新版本信息
# ---------------------------------------------------------------------------
log "查询最新稳定版版本号"
api="https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest"
json=""
if ! json="$(curl -fsSL --max-time 20 "$api" 2>/dev/null)"; then
    json="$(curl -fsSL --max-time 30 -x "$PROXY" "$api" 2>/dev/null)" || \
        die "无法获取 VS Code 版本信息（直连和代理均失败）"
fi

ver="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["productVersion"])' <<<"$json")"
sha="$(python3 -c 'import sys,json;print(json.load(sys.stdin).get("sha256hash",""))' <<<"$json")"
dl="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])' <<<"$json")"
fname="$(basename "${dl%%\?*}")"
deb="$VSCODE_DIR/$fname"
info "最新版本：$ver"
info "安装包：$fname"

# 官方 CDN 域名在国内常被污染/阻断，Microsoft 软件源里的同一个包可以正常访问
msurl="https://packages.microsoft.com/repos/code/pool/main/c/code/$fname"
if ! fetch "$msurl" "$deb" proxy; then
    warn "Microsoft 软件源下载失败，尝试官方 CDN"
    fetch "$dl" "$deb" auto || die "VS Code 安装包下载失败"
fi
verify_sha256 "$deb" "$sha" || die "VS Code 安装包校验失败"

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
log "安装 VS Code $ver"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb" || {
    warn "apt 安装失败，尝试 dpkg + 修复依赖"
    $SUDO dpkg -i "$deb" || true
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -f
}

command -v code >/dev/null 2>&1 || die "安装后找不到 code 命令"
log "完成"
info "版本：$(code --version | head -n1)"
info "路径：$(command -v code)"
info "安装包保留在：$deb"
info "日志：$LOG_FILE"
