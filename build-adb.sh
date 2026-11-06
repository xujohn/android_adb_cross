#!/usr/bin/env bash
#
# build-adb.sh
#
# 从源码编译指定版本的 adb（Android Debug Bridge），支持交叉编译到 aarch64（glibc），
# 并可选择安装到本机或远程主机。
#
# 功能：
#   1. --list            列出所有可编译的版本（在线查询 GitHub releases）。
#   2. --version <版本>  指定版本；缺省为当前正在使用的版本（37.0.0p1）。
#   3. --arch <架构>     指定目标架构；缺省为本机架构。
#                        指定 aarch64 时从 x86_64 交叉编译（glibc）。
#   4. --no-install      只编译，不安装。
#   5. --host <主机>     通过 SSH 安装到远程主机；缺省安装到本机（直接拷贝）。
#   6. --static/--shared 选择静态或动态（默认）链接。
#   7. --cc/--cxx        指定 C/C++ 编译器。
#   8. --glibc <目录>    指定 glibc 的位置（前缀布局或 sysroot 布局）。
#   9. --sysroot <目录>  使用目标 rootfs 作为第三方库/头文件来源（交叉编译）。
#  10. --clean          清理生成文件（解压源码、构建目录、sysroot/staging），保留下载包。
#  11. --debug          显示脚本执行的每条命令（set -x）。
#
# 说明：
#   - 使用 nmeum/android-tools 的 CMake 构建系统（Arch/Alpine 官方打包同款），
#     源码版本与 Google platform-tools 对应，无需下载整个 AOSP。
#   - 本机编译时开启 mDNS（无线调试发现），并使用内置 fmt / libusb，
#     避免 Ubuntu 24.04 自带版本过旧导致编译失败。
#   - 交叉编译到 aarch64 时：
#       * 使用 Ubuntu ports 的 arm64 .deb 在本地搭建 glibc sysroot（不修改系统源）；
#       * 依赖包与解压后的 sysroot 都保留在下载目录，不删除；
#       * 由于缺少 aarch64 的 Rust 标准库，自动关闭 mDNS；
#       * 交叉编译产物归档到 <prefix>/versions/<ver>/aarch64/adb，
#         不会覆盖本机的 adb；要部署到 aarch64 主机请用 --host。
#   - 静态链接（--static）会关闭 udev 与 mDNS：
#       * Ubuntu 不提供 libudev.a，静态链接时无法链接 udev；
#       * Rust/mDNS 静态链接需要 libgcc_s，静态链接时不可用。
#     静态产物命名带 -static 后缀，不会覆盖同版本的动态产物。
#   - --sysroot 用于直接使用目标设备 rootfs（例如 Yocto/Buildroot 产物）：
#       * 只从其中取第三方库、头文件和 pkg-config（protobuf/zlib/lz4/zstd/udev 等）；
#       * glibc 仍由交叉编译器自带（或 --glibc 指定），不会混入目标 rootfs 的 libc，
#         从而避免 lib64 布局、缺失 libgcc_s/libstdc++ 开发链接等问题；
#       * 自动识别 usr/lib64、usr/lib/<triple> 等库目录；
#       * 目标 rootfs 缺 brotli 开发包时，自动回退到 Ubuntu arm64 依赖并优先静态链接；
#       * 目标 rootfs 自带 protoc 时，用 qemu-aarch64-static 运行它，保证与 libprotobuf 版本一致；
#       * 静态链接时若目标 rootfs 没有 libprotobuf.a，自动使用 Ubuntu arm64 依赖中的静态
#         protobuf（含匹配的头文件与 protoc），无需每次现场编译。
#   - --clean 删除解压后的源码、构建目录、自动 sysroot/staging 等生成文件，
#     但保留下载的 *.tar.xz 与 *.deb，便于下次快速重建。
#   - --debug 打开 set -x，显示脚本实际执行的每条命令。
#   - --cc/--cxx 指定的编译器必须已存在：存在时直接使用，不安装交叉编译器；
#     不存在时立即报错退出；只有未指定时才自动安装默认 aarch64 交叉编译器。
#   - --glibc 支持两种布局：
#       * sysroot 布局（<目录>/usr/include 存在）：使用 usr/include + usr/lib；
#       * 前缀布局（<目录>/include 存在）：使用 include + lib/lib64。
#   - 所有源码/压缩包保存在 /home/jmc/dl/android-tools，不删除，可重复使用。
#
# 用法：
#   bash build-adb.sh --list
#   bash build-adb.sh                                  # 编译并安装默认版本（本机架构）
#   bash build-adb.sh --version 36.0.1                 # 编译并安装指定版本
#   bash build-adb.sh -v 36.0.1 --no-install           # 只编译，不安装
#   bash build-adb.sh --arch aarch64                   # 交叉编译 aarch64（只归档）
#   bash build-adb.sh --arch aarch64 --host user@pi    # 交叉编译并 SSH 安装到 aarch64 主机
#   bash build-adb.sh -v 37.0.0p1 --host root@host --ssh-port 2222
#   bash build-adb.sh --arch aarch64 --static          # 交叉编译静态链接的 aarch64 adb
#   bash build-adb.sh --static                         # 本机静态链接
#   bash build-adb.sh --arch aarch64 --cc aarch64-linux-gnu-gcc --cxx aarch64-linux-gnu-g++
#   bash build-adb.sh --arch aarch64 --glibc /usr/aarch64-linux-gnu
#
set -Eeuo pipefail

PROXY="${PROXY:-http://192.168.2.96:7897}"
DL_DIR="${DL_DIR:-/home/jmc/dl}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/android-tools}"
# 缺省版本 = 当前系统正在使用的版本
ADB_VERSION="${ADB_VERSION:-37.0.0p1}"
JOBS="${JOBS:-$(nproc)}"
USE_LATEST=0
LIST_VERSIONS=0
DO_INSTALL=1
CLEAN_GENERATED=0
DEBUG=0
TARGET_HOST=""
SSH_PORT=""
PORTS_MIRROR="${PORTS_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
LINK_MODE="shared"          # shared（默认）或 static
CC_BIN=""                   # 指定的 C 编译器
CXX_BIN=""                  # 指定的 C++ 编译器
CC_USER_SPECIFIED=0         # 用户是否显式指定了 --cc
CXX_USER_SPECIFIED=0        # 用户是否显式指定了 --cxx
GLIBC_DIR=""                # 指定的 glibc 位置
SYSROOT_DIR=""              # 用户提供的交叉 sysroot

HOST_ARCH="$(uname -m)"
TARGET_ARCH="$HOST_ARCH"

# 交叉编译 aarch64 所需的 arm64 依赖包（从 Ubuntu ports 下载后解压成 sysroot）
CROSS_DEB_PACKAGES=(
    libprotobuf-dev libprotobuf32t64 libprotobuf-lite32t64
    libbrotli-dev libbrotli1
    liblz4-dev liblz4-1
    libpcre2-dev libpcre2-8-0
    libzstd-dev libzstd1
    libudev-dev libudev1
    zlib1g-dev zlib1g
    libcap-dev libcap2
)

# 在线查询失败时使用的内置版本列表
FALLBACK_VERSIONS=(
    37.0.0p1 37.0.0 36.0.1 35.0.2 35.0.1
    34.0.5 34.0.4 34.0.1 34.0.0 33.0.3p2
)

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  -L, --list             列出所有可编译的 adb 版本
  -v, --version <版本>   指定要编译的 adb 版本（默认: $ADB_VERSION）
  -l, --latest           编译 GitHub 上 android-tools 的最新版本
  -a, --arch <架构>      目标架构：x86_64/amd64 或 aarch64/arm64
                         （默认: 本机 $HOST_ARCH；aarch64 为交叉编译，使用 glibc）
      --ports-mirror <url>
                         aarch64 交叉编译时下载 arm64 依赖的软件源
                         （默认: $PORTS_MIRROR）
  -j, --jobs <N>         并行编译任务数（默认: $JOBS）
      --static           静态链接（不依赖目标系统的共享库）
      --shared           动态链接（默认）
      --link <方式>      链接方式：static 或 shared
      --cc <编译器>      指定 C 编译器（交叉编译默认: aarch64-linux-gnu-gcc）
                         指定的编译器必须已存在，否则直接报错；存在时不会安装交叉编译器
      --cxx <编译器>     指定 C++ 编译器（交叉编译默认: aarch64-linux-gnu-g++）
                         指定的编译器必须已存在，否则直接报错；存在时不会安装交叉编译器
      --glibc <目录>     指定 glibc 位置
                         支持前缀布局（include/ + lib/）或 sysroot 布局（usr/include）
      --sysroot <目录>   使用目标 rootfs 作为第三方库/头文件来源（交叉编译）
                         只取库/头文件/pkg-config，glibc 仍由交叉编译器提供
      --no-install       只编译，不安装（默认会安装）
      --install          编译后安装（默认行为）
      --clean            删除所有生成文件（解压源码、构建目录、sysroot/staging），
                         保留下载的源码包和 .deb，然后退出
      --debug            显示脚本执行的每条命令（set -x）
  -H, --host <主机>      通过 SSH 安装到远程主机，格式 [user@]host
                         不指定时安装到本机（直接拷贝，不走 SSH）
      --ssh-port <端口>  SSH 端口（默认 22）
  -p, --prefix <目录>    安装前缀（默认: $INSTALL_PREFIX）
      --dl-dir <目录>    下载目录（默认: $DL_DIR）
      --proxy <url>      代理地址（默认: $PROXY）
  -h, --help             显示帮助

示例:
  $(basename "$0") --list
  $(basename "$0")
  $(basename "$0") --version 36.0.1
  $(basename "$0") --version 36.0.1 --no-install
  $(basename "$0") --arch aarch64
  $(basename "$0") --arch aarch64 --host pi@192.168.2.50
  $(basename "$0") --host user@192.168.2.50
  $(basename "$0") -v 37.0.0p1 -H root@host --ssh-port 2222
  $(basename "$0") --arch aarch64 --static
  $(basename "$0") --static --no-install
  $(basename "$0") --arch aarch64 --cc aarch64-linux-gnu-gcc --cxx aarch64-linux-gnu-g++
  $(basename "$0") --arch aarch64 --glibc /usr/aarch64-linux-gnu
  $(basename "$0") --arch aarch64 --sysroot /path/to/sysroot
  $(basename "$0") --arch aarch64 --static --sysroot /path/to/sysroot
  $(basename "$0") --clean
  $(basename "$0") --debug --arch aarch64 --sysroot /path/to/sysroot
EOF
}

die() { printf '\033[1;31m[错误] %s\033[0m\n' "$*" >&2; exit 1; }
log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[警告] %s\033[0m\n' "$*"; }

map_arch() {
    case "$1" in
        amd64|x86_64|x64)  echo "x86_64" ;;
        arm64|aarch64|armv8*|aarch64_be) echo "aarch64" ;;
        *) echo "" ;;
    esac
}

normalize_arch() {
    local arch
    arch="$(map_arch "$1")"
    [[ -n "$arch" ]] || die "不支持的架构: $1（支持 x86_64、aarch64）"
    echo "$arch"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -L|--list)    LIST_VERSIONS=1; shift ;;
        --clean)      CLEAN_GENERATED=1; shift ;;
        --debug)      DEBUG=1; shift ;;
        -v|--version) ADB_VERSION="$2"; shift 2 ;;
        --version=*)  ADB_VERSION="${1#*=}"; shift ;;
        -l|--latest)  USE_LATEST=1; shift ;;
        -a|--arch|--target-arch) TARGET_ARCH="$2"; shift 2 ;;
        --arch=*|--target-arch=*) TARGET_ARCH="${1#*=}"; shift ;;
        --ports-mirror)   PORTS_MIRROR="$2"; shift 2 ;;
        --ports-mirror=*) PORTS_MIRROR="${1#*=}"; shift ;;
        -j|--jobs)    JOBS="$2"; shift 2 ;;
        --jobs=*)     JOBS="${1#*=}"; shift ;;
        --static)     LINK_MODE="static"; shift ;;
        --shared)     LINK_MODE="shared"; shift ;;
        --link)       LINK_MODE="$2"; shift 2 ;;
        --link=*)     LINK_MODE="${1#*=}"; shift ;;
        --cc)         CC_BIN="$2"; CC_USER_SPECIFIED=1; shift 2 ;;
        --cc=*)       CC_BIN="${1#*=}"; CC_USER_SPECIFIED=1; shift ;;
        --cxx)        CXX_BIN="$2"; CXX_USER_SPECIFIED=1; shift 2 ;;
        --cxx=*)      CXX_BIN="${1#*=}"; CXX_USER_SPECIFIED=1; shift ;;
        --glibc)      GLIBC_DIR="$2"; shift 2 ;;
        --glibc=*)    GLIBC_DIR="${1#*=}"; shift ;;
        --sysroot)    SYSROOT_DIR="$2"; shift 2 ;;
        --sysroot=*)  SYSROOT_DIR="${1#*=}"; shift ;;
        --no-install) DO_INSTALL=0; shift ;;
        --install)    DO_INSTALL=1; shift ;;
        -H|--host)    TARGET_HOST="$2"; shift 2 ;;
        --host=*)     TARGET_HOST="${1#*=}"; shift ;;
        --ssh-port)   SSH_PORT="$2"; shift 2 ;;
        --ssh-port=*) SSH_PORT="${1#*=}"; shift ;;
        -p|--prefix)  INSTALL_PREFIX="$2"; shift 2 ;;
        --prefix=*)   INSTALL_PREFIX="${1#*=}"; shift ;;
        --dl-dir)     DL_DIR="$2"; shift 2 ;;
        --dl-dir=*)   DL_DIR="${1#*=}"; shift ;;
        --proxy)      PROXY="$2"; shift 2 ;;
        --proxy=*)    PROXY="${1#*=}"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "未知参数: $1（使用 --help 查看用法）" ;;
    esac
done

if (( DEBUG )); then
    PS4='+ [${LINENO}] '
    set -x
fi

[[ "$ADB_VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || die "版本号格式不合法: $ADB_VERSION"
[[ "$JOBS" =~ ^[0-9]+$ ]] && (( JOBS > 0 )) || die "并行任务数不合法: $JOBS"
if [[ -n "$SSH_PORT" ]]; then
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT > 0 && SSH_PORT < 65536 )) || \
        die "SSH 端口不合法: $SSH_PORT"
fi
if (( ! DO_INSTALL )) && [[ -n "$TARGET_HOST" ]]; then
    warn "--no-install 已指定，忽略 --host $TARGET_HOST"
    TARGET_HOST=""
fi

case "$LINK_MODE" in
    static|shared) ;;
    *) die "--link 只支持 static 或 shared（当前: $LINK_MODE）" ;;
esac
STATIC_LINK=0
[[ "$LINK_MODE" == "static" ]] && STATIC_LINK=1
LINK_SUFFIX=""
if (( STATIC_LINK )); then
    LINK_SUFFIX="-static"
fi

HOST_ARCH="$(normalize_arch "$HOST_ARCH")"
TARGET_ARCH="$(normalize_arch "$TARGET_ARCH")"
CROSS=0
[[ "$TARGET_ARCH" != "$HOST_ARCH" ]] && CROSS=1
if (( CROSS )) && [[ "$TARGET_ARCH" != "aarch64" ]]; then
    die "目前只支持交叉编译到 aarch64（当前主机 $HOST_ARCH）"
fi

# 交叉编译时缺省使用 aarch64 交叉编译器，可被 --cc/--cxx 覆盖
if (( CROSS )); then
    CC_BIN="${CC_BIN:-aarch64-linux-gnu-gcc}"
    CXX_BIN="${CXX_BIN:-aarch64-linux-gnu-g++}"
fi

check_compiler() {
    local bin="$1" kind="$2"
    [[ -z "$bin" ]] && return 0
    if [[ "$bin" == */* ]]; then
        [[ -x "$bin" ]] || die "$kind 编译器不存在或不可执行: $bin"
    else
        command -v "$bin" >/dev/null 2>&1 || die "$kind 编译器不在 PATH 中: $bin"
    fi
}
# --list 只查询版本，不依赖本机工具链/glibc/sysroot，因此跳过这些校验
if (( ! LIST_VERSIONS && ! CLEAN_GENERATED )); then
    if (( CROSS )); then
        # 用户显式指定的编译器必须已经存在；不存在立即报错退出，
        # 不会为了它去安装交叉编译器。
        (( CC_USER_SPECIFIED ))  && check_compiler "$CC_BIN" "C"
        (( CXX_USER_SPECIFIED )) && check_compiler "$CXX_BIN" "C++"
        # 未指定的编译器使用默认交叉工具链，稍后由 install_deps 安装并校验
    else
        check_compiler "$CC_BIN" "C"
        check_compiler "$CXX_BIN" "C++"
    fi

    if [[ -n "$GLIBC_DIR" && ! -d "$GLIBC_DIR" ]]; then
        die "glibc 目录不存在: $GLIBC_DIR"
    fi
    if [[ -n "$SYSROOT_DIR" && ! -d "$SYSROOT_DIR" ]]; then
        die "sysroot 目录不存在: $SYSROOT_DIR"
    fi
fi

ADB_DIR="$DL_DIR/android-tools"
LOG_DIR="$DL_DIR/logs"
CROSS_ROOT="$ADB_DIR/cross/$TARGET_ARCH"
AUTO_SYSROOT="$CROSS_ROOT/sysroot"
CROSS_SYSROOT="$AUTO_SYSROOT"
CROSS_DEBS="$CROSS_ROOT/debs"
CROSS_TOOLCHAIN="$CROSS_ROOT/toolchain.cmake"
SYSROOT_STAGE="$CROSS_ROOT/sysroot-stage"
SYSROOT_LIBDIR=""
SYSROOT_INCDIR=""
SYSROOT_PCDIR=""
PROTOC_EXEC=""
PROTOBUF_INCLUDE_OVERRIDE=""
BUILD_SUBDIR="build"
(( CROSS )) && BUILD_SUBDIR="build-$TARGET_ARCH"
(( STATIC_LINK )) && BUILD_SUBDIR+="-static"

mkdir -p "$DL_DIR" "$ADB_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-adb-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'die "脚本在第 $LINENO 行执行失败（退出码 $?）"' ERR

# 清理所有生成文件，但保留下载的源码包/依赖包（*.tar.xz、*.deb）
clean_generated() {
    log "清理生成文件（保留下载的源码包与 .deb）"
    local d
    for d in "$ADB_DIR"/src-*; do
        [[ -d "$d" ]] || continue
        info "删除源码解压目录：$d"
        rm -rf "$d"
    done
    for d in "$ADB_DIR"/cross/*/sysroot \
             "$ADB_DIR"/cross/*/sysroot-stage \
             "$ADB_DIR"/cross/*/apt; do
        [[ -e "$d" ]] || continue
        info "删除生成目录：$d"
        rm -rf "$d"
    done
    for d in "$ADB_DIR"/cross/*/toolchain.cmake \
             "$ADB_DIR/static-prelude.cmake"; do
        [[ -e "$d" ]] || continue
        info "删除生成文件：$d"
        rm -f "$d"
    done
    info "已保留下载文件：$ADB_DIR/*.tar.xz、$ADB_DIR/cross/*/debs/*.deb"
}

if (( CLEAN_GENERATED )); then
    clean_generated
    log "清理完成"
    exit 0
fi

SUDO=""
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "需要 root 权限，但系统没有 sudo"
    SUDO="sudo"
    $SUDO -n true 2>/dev/null || warn "sudo 可能需要输入密码"
fi

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

# 已收录版本的官方 SHA256（发布页未提供校验文件，这里记录首次下载校验值）
adb_checksums() {
    case "$1" in
        37.0.0p1)
            ADB_SRC_SHA="2c6de1abe16b211c7d9f59276217e14fd9e0e18b20e331d3c84358f5dffd576e"
            ADB_VENDOR_SHA="0ab5d7b24cb20365f9dfeddace6720095b2f4a86e4eb69ee2cfc3465115c4f9a"
            ;;
        *)
            ADB_SRC_SHA=""
            ADB_VENDOR_SHA=""
            ;;
    esac
}

github_releases_json() {
    local api="https://api.github.com/repos/nmeum/android-tools/releases?per_page=100"
    if curl -fsSL --max-time 20 "$api" 2>/dev/null; then
        return 0
    fi
    curl -fsSL --max-time 40 -x "$PROXY" "$api" 2>/dev/null
}

github_latest_version() {
    local api="https://api.github.com/repos/nmeum/android-tools/releases/latest" json=""
    if ! json="$(curl -fsSL --max-time 20 "$api" 2>/dev/null)"; then
        json="$(curl -fsSL --max-time 30 -x "$PROXY" "$api" 2>/dev/null)" || return 1
    fi
    python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])' <<<"$json"
}

# ---------------------------------------------------------------------------
# 列出可用版本
# ---------------------------------------------------------------------------
list_versions() {
    printf '可编译的 adb 版本（来源：nmeum/android-tools releases，目标架构：%s）\n\n' \
        "$TARGET_ARCH"
    printf '  %-12s %-12s %s\n' "版本" "发布日期" "状态"
    printf '  %-12s %-12s %s\n' "------------" "------------" "----"

    local json="" tag date marks
    if json="$(github_releases_json)"; then
        while IFS=$'\t' read -r tag date; do
            marks=""
            [[ "$tag" == "$ADB_VERSION" ]] && marks+=" [默认]"
            [[ -f "$INSTALL_PREFIX/versions/$tag/adb" ]] && marks+=" [已编译]"
            [[ -f "$INSTALL_PREFIX/versions/$tag/adb-static" ]] && marks+=" [已编译-静态]"
            [[ -f "$INSTALL_PREFIX/versions/$tag/aarch64/adb" ]] && marks+=" [aarch64]"
            [[ -f "$INSTALL_PREFIX/versions/$tag/aarch64/adb-static" ]] && marks+=" [aarch64-静态]"
            printf '  %-12s %-12s%s\n' "$tag" "$date" "$marks"
        done < <(python3 -c '
import sys, json
for r in json.load(sys.stdin):
    print(r["tag_name"] + "\t" + r["published_at"][:10])
' <<<"$json")
    else
        warn "无法获取在线版本列表，显示内置列表"
        for tag in "${FALLBACK_VERSIONS[@]}"; do
            marks=""
            [[ "$tag" == "$ADB_VERSION" ]] && marks+=" [默认]"
            [[ -f "$INSTALL_PREFIX/versions/$tag/adb" ]] && marks+=" [已编译]"
            [[ -f "$INSTALL_PREFIX/versions/$tag/adb-static" ]] && marks+=" [已编译-静态]"
            [[ -f "$INSTALL_PREFIX/versions/$tag/aarch64/adb" ]] && marks+=" [aarch64]"
            [[ -f "$INSTALL_PREFIX/versions/$tag/aarch64/adb-static" ]] && marks+=" [aarch64-静态]"
            printf '  %-12s %-12s%s\n' "$tag" "-" "$marks"
        done
    fi

    printf '\n已编译版本目录：%s\n' "$INSTALL_PREFIX/versions"
    if [[ -d "$INSTALL_PREFIX/versions" ]] && \
       [[ -n "$(ls -A "$INSTALL_PREFIX/versions" 2>/dev/null)" ]]; then
        for tag in $(ls -1 "$INSTALL_PREFIX/versions" | sort -V); do
            printf '  %s' "$tag"
            [[ -f "$INSTALL_PREFIX/versions/$tag/adb" ]] && printf ' (本机 %s)' "$HOST_ARCH"
            [[ -f "$INSTALL_PREFIX/versions/$tag/adb-static" ]] && printf ' (本机 %s 静态)' "$HOST_ARCH"
            [[ -f "$INSTALL_PREFIX/versions/$tag/aarch64/adb" ]] && printf ' (aarch64)'
            [[ -f "$INSTALL_PREFIX/versions/$tag/aarch64/adb-static" ]] && printf ' (aarch64 静态)'
            printf '\n'
        done
    else
        printf '  （无）\n'
    fi
}

# ---------------------------------------------------------------------------
# 依赖
# ---------------------------------------------------------------------------
install_deps() {
    log "安装编译依赖"
    if [[ -n "$($SUDO dpkg --audit 2>/dev/null || true)" ]]; then
        warn "检测到 dpkg 有未完成的配置，尝试以非交互方式修复"
        echo "lightdm shared/default-x-display-manager select lightdm" \
            | $SUDO debconf-set-selections 2>/dev/null || true
        $SUDO env DEBIAN_FRONTEND=noninteractive dpkg --configure -a || \
            warn "dpkg --configure -a 仍有失败项，继续"
    fi
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq || \
        warn "apt-get update 失败，继续使用现有索引"

    local pkgs=(
        curl ca-certificates git
        build-essential cmake ninja-build pkg-config
        python3 unzip zip file xz-utils
        libusb-1.0-0-dev libudev-dev libpcre2-dev
        libprotobuf-dev protobuf-compiler
        libbrotli-dev libzstd-dev liblz4-dev
        libabsl-dev libfmt-dev libgtest-dev googletest
        corrosion cargo rustc
    )
    if (( CROSS )); then
        pkgs+=(
            qemu-user-static
        )
        # 只有用户没有显式指定对应编译器时才安装默认交叉工具链；
        # 用户指定的编译器若不存在，已在参数校验阶段报错退出。
        if (( ! CC_USER_SPECIFIED )); then
            info "未指定 --cc，安装默认 aarch64 C 交叉编译器"
            pkgs+=(gcc-aarch64-linux-gnu)
        fi
        if (( ! CXX_USER_SPECIFIED )); then
            info "未指定 --cxx，安装默认 aarch64 C++ 交叉编译器"
            pkgs+=(g++-aarch64-linux-gnu)
        fi
        if (( CC_USER_SPECIFIED && CXX_USER_SPECIFIED )); then
            info "使用用户指定的 C/C++ 编译器，跳过安装交叉编译器"
        fi
    fi
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" || \
        warn "部分依赖安装失败，编译时可能自动回退到内置依赖"
}

# ---------------------------------------------------------------------------
# aarch64 交叉编译环境：用 Ubuntu ports 的 arm64 .deb 搭建 glibc sysroot
# ---------------------------------------------------------------------------
# 用 Ubuntu ports 的 arm64 .deb 搭建依赖 sysroot（保留，不删除）
prepare_auto_sysroot() {
    local dest="$AUTO_SYSROOT"
    command -v dpkg-deb >/dev/null 2>&1 || die "缺少 dpkg-deb"
    mkdir -p "$CROSS_DEBS" "$CROSS_ROOT"

    if [[ -f "$dest/.prepared" ]]; then
        info "依赖 sysroot 已存在，跳过：$dest"
        return 0
    fi

    local aptdir="$CROSS_ROOT/apt"
    mkdir -p "$aptdir/etc/apt/sources.list.d" \
             "$aptdir/var/lib/apt/lists/partial" \
             "$aptdir/var/cache/apt/archives/partial" \
             "$aptdir/var/lib/dpkg"
    touch "$aptdir/var/lib/dpkg/status"
    cat > "$aptdir/etc/apt/sources.list" <<EOF
deb [arch=arm64] $PORTS_MIRROR noble main universe
deb [arch=arm64] $PORTS_MIRROR noble-updates main universe
deb [arch=arm64] $PORTS_MIRROR noble-security main universe
EOF

    local -a apt_opts=(
        -o "Dir::Etc::sourcelist=$aptdir/etc/apt/sources.list"
        -o "Dir::Etc::sourceparts=-"
        -o "Dir::State::lists=$aptdir/var/lib/apt/lists"
        -o "Dir::State::status=$aptdir/var/lib/dpkg/status"
        -o "Dir::Cache=$aptdir/var/cache/apt"
        -o "APT::Architecture=arm64"
        -o "APT::Architectures::=arm64"
        -o "Acquire::Languages=none"
    )

    local have_debs
    have_debs="$(ls -1 "$CROSS_DEBS"/*.deb 2>/dev/null | wc -l || true)"
    if (( have_debs < ${#CROSS_DEB_PACKAGES[@]} )); then
        info "从 $PORTS_MIRROR 下载 arm64 依赖包"
        if ! apt-get "${apt_opts[@]}" update; then
            warn "直连 $PORTS_MIRROR 失败，尝试通过代理 $PROXY"
            apt-get "${apt_opts[@]}" -o "Acquire::http::Proxy=$PROXY" update || \
                die "无法获取 arm64 软件包索引"
        fi
        if ! ( cd "$CROSS_DEBS" && \
               apt-get "${apt_opts[@]}" download "${CROSS_DEB_PACKAGES[@]}" ); then
            warn "直连下载失败，尝试通过代理 $PROXY"
            ( cd "$CROSS_DEBS" && \
              apt-get "${apt_opts[@]}" -o "Acquire::http::Proxy=$PROXY" \
                  download "${CROSS_DEB_PACKAGES[@]}" ) || \
                die "下载 arm64 依赖包失败"
        fi
    else
        info "arm64 依赖包已存在，跳过下载：$CROSS_DEBS"
    fi

    info "解压 arm64 依赖到 $dest"
    rm -rf "$dest"
    mkdir -p "$dest"
    local deb
    for deb in "$CROSS_DEBS"/*.deb; do
        dpkg-deb -x "$deb" "$dest" || die "解压失败：$deb"
    done
    touch "$dest/.prepared"
}

# 为目标 sysroot 建立第三方库/头文件/pkg-config 的 staging 目录。
# 只使用其中的第三方库，glibc 仍由编译器（或 --glibc）提供，避免
# 目标 rootfs 中 lib64 布局、缺失 libgcc_s/libstdc++ 开发链接等问题。
prepare_sysroot_stage() {
    local stage="$SYSROOT_STAGE"
    local triple="$TARGET_ARCH-linux-gnu"
    rm -rf "$stage"
    mkdir -p "$stage/lib" "$stage/include" "$stage/pkgconfig"

    local -a libdirs=() incdirs=() pcdirs=()
    local d f n
    for d in "usr/lib/$triple" usr/lib64 usr/lib "lib/$triple" lib64 lib; do
        [[ -d "$CROSS_SYSROOT/$d" ]] && libdirs+=("$CROSS_SYSROOT/$d")
    done
    (( ${#libdirs[@]} )) || die "在 sysroot 下找不到库目录：$CROSS_SYSROOT"
    for d in usr/include include; do
        [[ -d "$CROSS_SYSROOT/$d" ]] && incdirs+=("$CROSS_SYSROOT/$d")
    done
    (( ${#incdirs[@]} )) || warn "sysroot 中没有 include 目录：$CROSS_SYSROOT"

    # glibc / 编译器运行时库不进入 staging，避免链接时覆盖编译器自带的版本
    local skip_re='^(libc|libm|libmvec|libpthread|libdl|librt|libutil|libresolv|libanl|libnsl|libcrypt|libgcc_s|libstdc\+\+|libatomic|libgomp|libasan|libubsan|liblsan|libtsan|libitm|libquadmath|ld-linux)(\.so|\.a)(\.|$)'
    for d in "${libdirs[@]}"; do
        for f in "$d"/*; do
            [[ -e "$f" ]] || continue
            n="$(basename "$f")"
            [[ "$n" =~ $skip_re ]] && continue
            [[ -e "$stage/lib/$n" ]] || ln -s "$f" "$stage/lib/$n"
        done
    done

    # 与项目内置依赖冲突的头文件目录不进入 staging（项目自带 boringssl/libusb/fmt）
    for d in "${incdirs[@]}"; do
        for f in "$d"/*; do
            [[ -e "$f" ]] || continue
            n="$(basename "$f")"
            case "$n" in
                openssl|libusb-1.0|libusb.h|fmt|gtest|gmock) continue ;;
            esac
            [[ -e "$stage/include/$n" ]] || ln -s "$f" "$stage/include/$n"
        done
    done
    # gtest_prod.h 只需要编译期头文件，从宿主机补上。
    # 单独放到 host-include，避免把宿主机 /usr/include 下的 glibc 头文件带进来。
    mkdir -p "$stage/host-include"
    for d in /usr/include/gtest /usr/include/gmock; do
        [[ -d "$d" ]] && ln -sfn "$d" "$stage/host-include/$(basename "$d")"
    done
    CFLAGS_EXTRA+=" -I$stage/host-include"
    CXXFLAGS_EXTRA+=" -I$stage/host-include"

    for d in "${libdirs[@]}"; do
        [[ -d "$d/pkgconfig" ]] && pcdirs+=("$d/pkgconfig")
    done
    [[ -d "$CROSS_SYSROOT/usr/share/pkgconfig" ]] && \
        pcdirs+=("$CROSS_SYSROOT/usr/share/pkgconfig")

    # 重写 .pc：libdir/includedir 指向 staging，绝对 /usr 路径也改写到 staging
    for d in "${pcdirs[@]}"; do
        for f in "$d"/*.pc; do
            [[ -e "$f" ]] || continue
            n="$(basename "$f")"
            [[ -e "$stage/pkgconfig/$n" ]] && continue
            sed -E \
                -e "s#^prefix=.*#prefix=$stage#" \
                -e "s#^exec_prefix=.*#exec_prefix=$stage#" \
                -e "s#^libdir=.*#libdir=$stage/lib#" \
                -e "s#^includedir=.*#includedir=$stage/include#" \
                -e "s#/usr/lib/$triple#$stage/lib#g" \
                -e "s#/usr/lib64#$stage/lib#g" \
                -e "s#/usr/lib#$stage/lib#g" \
                -e "s#/usr/include#$stage/include#g" \
                "$f" > "$stage/pkgconfig/$n"
        done
    done

    # 目标 rootfs 通常没有 brotli 开发包；adb 又强制依赖它，缺省从
    # Ubuntu arm64 依赖中回退（优先静态链接，避免目标机缺少 libbrotli）
    if [[ ! -e "$stage/pkgconfig/libbrotlicommon.pc" ]]; then
        prepare_brotli_fallback
    fi

    SYSROOT_LIBDIR="$stage/lib"
    SYSROOT_INCDIR="$stage/include"
    SYSROOT_PCDIR="$stage/pkgconfig"
    LDFLAGS_EXTRA+=" -L$stage/lib -Wl,-rpath-link,$stage/lib"
    info "第三方库 staging：$stage"
}

prepare_brotli_fallback() {
    local stage="$SYSROOT_STAGE"
    local triple="$TARGET_ARCH-linux-gnu"
    local libdir="" incdir="" d

    local -a fb_libdirs=(
        "$AUTO_SYSROOT/usr/lib/$triple"
        "$AUTO_SYSROOT/usr/lib64"
        "$AUTO_SYSROOT/usr/lib"
    )
    for d in "${fb_libdirs[@]}"; do
        if [[ -f "$d/libbrotlicommon.a" || -f "$d/libbrotlicommon.so" ]]; then
            libdir="$d"; break
        fi
    done

    if [[ -z "$libdir" ]]; then
        info "目标 sysroot 缺少 brotli，准备 Ubuntu arm64 依赖用于回退"
        prepare_auto_sysroot
        for d in "${fb_libdirs[@]}"; do
            if [[ -f "$d/libbrotlicommon.a" || -f "$d/libbrotlicommon.so" ]]; then
                libdir="$d"; break
            fi
        done
    fi
    [[ -n "$libdir" ]] || die "目标 sysroot 缺少 brotli，且无法准备回退依赖"

    for d in "$AUTO_SYSROOT/usr/include" "$AUTO_SYSROOT/include"; do
        [[ -d "$d/brotli" ]] && { incdir="$d"; break; }
    done
    [[ -n "$incdir" ]] && ln -sfn "$incdir/brotli" "$stage/include/brotli"

    local mode="动态"
    if [[ -f "$libdir/libbrotlicommon.a" ]]; then
        mode="静态"
        # 若目标 sysroot 恰好只带了 brotli 运行库而没有 .pc，优先使用静态回退，
        # 避免链接到目标机上可能不存在的 libbrotli*.so
        rm -f "$stage/lib"/libbrotli*.so*
        local f
        for f in "$libdir"/libbrotli*.a; do
            [[ -e "$f" ]] && ln -sfn "$f" "$stage/lib/"
        done
    else
        local f
        for f in "$libdir"/libbrotli*.so*; do
            [[ -e "$f" ]] && ln -sfn "$f" "$stage/lib/"
        done
    fi

    # 三个模块只让 common 输出链接参数，保证静态库顺序 enc -> dec -> common
    local m libs=""
    for m in common dec enc; do
        libs=""
        if [[ "$m" == "common" ]]; then
            libs="-L$stage/lib -lbrotlienc -lbrotlidec -lbrotlicommon"
        fi
        cat > "$stage/pkgconfig/libbrotli$m.pc" <<EOF
prefix=$stage
libdir=$stage/lib
includedir=$stage/include
Name: libbrotli$m
Description: Brotli $m (fallback)
Version: 1.1.0
Libs: $libs
Cflags: -I\${includedir}
EOF
    done
    warn "目标 sysroot 缺少 brotli，已使用 Ubuntu arm64 依赖回退（${mode}链接 brotli）"
}

# 如果 sysroot 自带 protoc，用 qemu 运行它，保证与目标 libprotobuf 版本一致
prepare_protoc() {
    local host_protoc=""
    host_protoc="$(command -v protoc 2>/dev/null || true)"
    PROTOC_EXEC="$host_protoc"

    local target_protoc="$CROSS_SYSROOT/usr/bin/protoc"
    if [[ -x "$target_protoc" ]] && command -v qemu-aarch64-static >/dev/null 2>&1; then
        local wrapper="$SYSROOT_STAGE/protoc"
        cat > "$wrapper" <<EOF
#!/bin/sh
exec qemu-aarch64-static -L "$CROSS_SYSROOT" "$target_protoc" "\$@"
EOF
        chmod +x "$wrapper"
        PROTOC_EXEC="$wrapper"
        info "使用 sysroot 中的 protoc（qemu）：$target_protoc"
    elif [[ -x "$target_protoc" ]]; then
        warn "sysroot 自带 protoc，但缺少 qemu-aarch64-static，改用宿主机 protoc"
    fi
}

prepare_cross_sysroot() {
    log "准备 aarch64 交叉编译环境"

    if [[ -n "$SYSROOT_DIR" ]]; then
        CROSS_SYSROOT="$(cd "$SYSROOT_DIR" && pwd)"
        info "使用指定的 sysroot：$CROSS_SYSROOT（第三方库来自该 sysroot）"
        prepare_sysroot_stage
        prepare_protoc
    else
        CROSS_SYSROOT="$AUTO_SYSROOT"
        prepare_auto_sysroot
    fi

    # 生成 CMake toolchain 文件（每次覆盖，保证路径正确）
    local -a find_roots=("$CROSS_SYSROOT" "/usr/$TARGET_ARCH-linux-gnu")
    [[ -n "$GLIBC_DIR" ]] && find_roots+=("$GLIBC_DIR")
    local find_root_cmake="" r
    for r in "${find_roots[@]}"; do
        find_root_cmake+="\"$r\" "
    done

    local stage_cmake=""
    if [[ -n "$SYSROOT_LIBDIR" ]]; then
        stage_cmake=$(cat <<EOF
# 使用目标 sysroot 的第三方库 staging（glibc 由编译器/--glibc 提供）
set(CMAKE_LIBRARY_PATH "$SYSROOT_LIBDIR")
unset(ENV{PKG_CONFIG_SYSROOT_DIR})
set(ENV{PKG_CONFIG_PATH} "")
set(ENV{PKG_CONFIG_LIBDIR} "$SYSROOT_PCDIR")
EOF
)
    else
        stage_cmake=$(cat <<EOF
set(ENV{PKG_CONFIG_SYSROOT_DIR} "$CROSS_SYSROOT")
set(ENV{PKG_CONFIG_LIBDIR} "$CROSS_SYSROOT/usr/lib/$TARGET_ARCH-linux-gnu/pkgconfig:$CROSS_SYSROOT/usr/share/pkgconfig")
EOF
)
    fi

    cat > "$CROSS_TOOLCHAIN" <<EOF
# CMake toolchain for cross-compiling adb to $TARGET_ARCH (glibc)
# 由 build-adb.sh 自动生成
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR $TARGET_ARCH)

set(CMAKE_C_COMPILER "$CC_BIN")
set(CMAKE_CXX_COMPILER "$CXX_BIN")

# 第三方库的 sysroot；glibc 默认由交叉编译器自带的 /usr/$TARGET_ARCH-linux-gnu 提供
set(CMAKE_FIND_ROOT_PATH $find_root_cmake)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

$stage_cmake
EOF
    info "toolchain 文件：$CROSS_TOOLCHAIN"
    info "C 编译器：$CC_BIN"
    info "C++ 编译器：$CXX_BIN"
}

# ---------------------------------------------------------------------------
# glibc 位置 / 静态链接设置
# ---------------------------------------------------------------------------
CFLAGS_EXTRA=""
CXXFLAGS_EXTRA=""
LDFLAGS_EXTRA=""
GLIBC_LIBDIR=""
STATIC_PRELUDE=""
PROTOBUF_STATIC=""
STATIC_LIBDIR=""

setup_glibc() {
    [[ -n "$GLIBC_DIR" ]] || return 0
    GLIBC_DIR="$(cd "$GLIBC_DIR" && pwd)"

    local inc=""
    local -a libdirs=()

    if [[ -d "$GLIBC_DIR/usr/include" ]]; then
        # sysroot 布局：<目录>/usr/include + <目录>/usr/lib/<triple>
        inc="$GLIBC_DIR/usr/include"
        [[ -d "$GLIBC_DIR/usr/lib/$TARGET_ARCH-linux-gnu" ]] && \
            libdirs+=("$GLIBC_DIR/usr/lib/$TARGET_ARCH-linux-gnu")
        [[ -d "$GLIBC_DIR/usr/lib64" ]] && libdirs+=("$GLIBC_DIR/usr/lib64")
        [[ -d "$GLIBC_DIR/usr/lib" ]] && libdirs+=("$GLIBC_DIR/usr/lib")
        [[ -d "$GLIBC_DIR/lib64" ]] && libdirs+=("$GLIBC_DIR/lib64")
        [[ -d "$GLIBC_DIR/lib" ]] && libdirs+=("$GLIBC_DIR/lib")
        info "glibc：$GLIBC_DIR（sysroot 布局）"
    elif [[ -d "$GLIBC_DIR/include" ]]; then
        # 前缀布局：<目录>/include + <目录>/lib（或 lib64）
        inc="$GLIBC_DIR/include"
        [[ -d "$GLIBC_DIR/lib64" ]] && libdirs+=("$GLIBC_DIR/lib64")
        [[ -d "$GLIBC_DIR/lib" ]] && libdirs+=("$GLIBC_DIR/lib")
        info "glibc：$GLIBC_DIR（前缀布局）"
    else
        die "无法识别 glibc 布局：$GLIBC_DIR（需要 usr/include 或 include 目录）"
    fi

    (( ${#libdirs[@]} )) || die "在 $GLIBC_DIR 下找不到库目录（lib/lib64/usr/lib）"
    GLIBC_LIBDIR="${libdirs[0]}"

    # 用 -isystem/-B/-L 而不是 --sysroot，避免把宿主机的 /usr/include
    # （gtest 等仅编译期需要的头文件）排除掉。
    CFLAGS_EXTRA+=" -isystem $inc"
    CXXFLAGS_EXTRA+=" -isystem $inc"
    local d
    for d in "${libdirs[@]}"; do
        LDFLAGS_EXTRA+=" -B$d -L$d -Wl,-rpath-link,$d"
    done
}

find_static_lib() {
    local name="$1"; shift
    local d
    for d in "$@"; do
        [[ -n "$d" && -f "$d/$name" ]] && { printf '%s\n' "$d/$name"; return 0; }
    done
    return 1
}

setup_static() {
    (( STATIC_LINK )) || return 0

    local -a libdirs=()
    if (( CROSS )); then
        # staging 模式：目标 sysroot 的第三方库优先（含 .a 与 .so）
        [[ -n "$SYSROOT_LIBDIR" ]] && libdirs+=("$SYSROOT_LIBDIR")
        libdirs+=(
            "$CROSS_SYSROOT/usr/lib/$TARGET_ARCH-linux-gnu"
            "$CROSS_SYSROOT/usr/lib"
            "/usr/$TARGET_ARCH-linux-gnu/lib"
        )
    else
        local multiarch=""
        multiarch="$("${CC_BIN:-cc}" -print-multiarch 2>/dev/null || true)"
        [[ -n "$multiarch" ]] && libdirs+=("/usr/lib/$multiarch" "/lib/$multiarch")
        libdirs+=(/usr/lib /usr/lib64 /lib /lib64 /usr/local/lib)
    fi
    [[ -n "$GLIBC_LIBDIR" ]] && libdirs+=("$GLIBC_LIBDIR")

    STATIC_LIBDIR="${libdirs[0]}"

    # 目标 rootfs 通常只有动态库；静态链接时改用 Ubuntu arm64 依赖中的静态库。
    # 该依赖包已经下载并解压，无需每次现场编译 protobuf。
    if (( CROSS )) && [[ -n "$SYSROOT_LIBDIR" ]] && \
       ! find_static_lib libprotobuf.a "$SYSROOT_LIBDIR" >/dev/null; then
        prepare_auto_sysroot
        local auto_lib=""
        auto_lib="$(find_static_lib libprotobuf.a \
            "$AUTO_SYSROOT/usr/lib/$TARGET_ARCH-linux-gnu" \
            "$AUTO_SYSROOT/usr/lib64" \
            "$AUTO_SYSROOT/usr/lib")" || true
        [[ -n "$auto_lib" ]] || \
            die "目标 sysroot 和 Ubuntu arm64 依赖中都没有 libprotobuf.a，无法静态链接"

        local auto_libdir
        auto_libdir="$(dirname "$auto_lib")"
        libdirs=("$auto_libdir" "${libdirs[@]}")
        STATIC_LIBDIR="$auto_libdir"

        # 必须使用与 libprotobuf.a 匹配的头文件和 protoc（Ubuntu arm64 为 3.21.12）
        [[ -d "$AUTO_SYSROOT/usr/include/google/protobuf" ]] || \
            die "Ubuntu arm64 依赖中缺少 protobuf 头文件"
        PROTOBUF_INCLUDE_OVERRIDE="$AUTO_SYSROOT/usr/include"
        rm -f "$SYSROOT_STAGE/include/google" "$SYSROOT_STAGE/include/absl"

        local host_protoc=""
        host_protoc="$(command -v protoc 2>/dev/null || true)"
        [[ -n "$host_protoc" ]] || die "静态回退需要宿主机 protoc（protobuf-compiler）"
        PROTOC_EXEC="$host_protoc"

        warn "目标 sysroot 无 libprotobuf.a，改用 Ubuntu arm64 依赖中的静态 protobuf"
        info "静态 protobuf 库：$auto_lib"
        info "静态 protobuf 头文件：$PROTOBUF_INCLUDE_OVERRIDE"
        info "静态 protobuf protoc：$PROTOC_EXEC ($("$PROTOC_EXEC" --version 2>/dev/null || true))"
    fi

    PROTOBUF_STATIC="$(find_static_lib libprotobuf.a "${libdirs[@]}")" || \
        die "静态链接需要 libprotobuf.a（请安装 libprotobuf-dev，或检查 --glibc/--sysroot）"
    info "静态链接 libprotobuf：$PROTOBUF_STATIC"

    STATIC_PRELUDE="$ADB_DIR/static-prelude.cmake"
    cat > "$STATIC_PRELUDE" <<'EOF'
# 由 build-adb.sh 生成：静态链接所需的 CMake 设置
# 在 project() 之后覆盖平台默认的库后缀，只查找 .a
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
# 与 CMAKE_EXE_LINKER_FLAGS 中的 -Wl,--start-group 配对，解决静态库顺序问题
if(NOT DEFINED _ADB_STATIC_GROUP_CLOSED)
  set(_ADB_STATIC_GROUP_CLOSED TRUE)
  set(CMAKE_CXX_STANDARD_LIBRARIES "${CMAKE_CXX_STANDARD_LIBRARIES} -Wl,--end-group")
  set(CMAKE_C_STANDARD_LIBRARIES "${CMAKE_C_STANDARD_LIBRARIES} -Wl,--end-group")
endif()
EOF

    LDFLAGS_EXTRA+=" -static -Wl,--start-group"
    local d
    for d in "${libdirs[@]}"; do
        [[ -n "$d" ]] && LDFLAGS_EXTRA+=" -L$d"
    done
}

# 用 qemu 验证交叉编译产物（可选）
verify_cross_binary() {
    local bin="$1"
    command -v qemu-aarch64-static >/dev/null 2>&1 || return 0
    info "用 qemu-aarch64 验证交叉编译产物"

    local -a qargs=()
    if (( ! STATIC_LINK )); then
        if [[ -n "$SYSROOT_LIBDIR" ]]; then
            # staging 模式：运行时库全部来自目标 rootfs
            qargs+=(-L "$CROSS_SYSROOT")
        else
            [[ -d /usr/$TARGET_ARCH-linux-gnu ]] || return 0
            local libpath="$CROSS_SYSROOT/usr/lib/$TARGET_ARCH-linux-gnu"
            [[ -n "$GLIBC_LIBDIR" ]] && libpath+=":$GLIBC_LIBDIR"
            qargs+=(-L "/usr/$TARGET_ARCH-linux-gnu" -E "LD_LIBRARY_PATH=$libpath")
        fi
    fi

    qemu-aarch64-static "${qargs[@]}" "$bin" version 2>&1 | sed 's/^/    /' || \
        warn "qemu 验证失败（可能缺少运行库），产物仍已生成"
}

# ---------------------------------------------------------------------------
# 编译
# ---------------------------------------------------------------------------
BUILT_ADB=""

# 修补 vendor 源码以适配较新的 glibc / 编译器
patch_vendor_sources() {
    local work="$1"
    local hdr="$work/vendor/core/libcutils/include/cutils/memory.h"
    [[ -f "$hdr" ]] || return 0

    if grep -q '__GLIBC_MINOR__ < 38' "$hdr"; then
        info "vendor 源码已修补（strlcpy）"
        return 0
    fi

    # glibc >= 2.38 自带 strlcpy，项目里的重复声明会与系统头文件冲突
    sed -i 's@^#if defined(__GLIBC__) || defined(_WIN32)$@#if defined(_WIN32) || (defined(__GLIBC__) \&\& (__GLIBC__ < 2 || (__GLIBC__ == 2 \&\& __GLIBC_MINOR__ < 38)))@' "$hdr"
    grep -q '__GLIBC_MINOR__ < 38' "$hdr" || die "修补 cutils/memory.h 失败：$hdr"
    info "已修补 cutils/memory.h 的 strlcpy 声明（兼容 glibc >= 2.38）"
}

# 构建目录签名：编译器/sysroot/链接方式变化时自动清理旧 CMake 缓存
build_signature() {
    printf '%s\n' \
        "target=$TARGET_ARCH" \
        "cross=$CROSS" \
        "link=$LINK_MODE" \
        "cc=$CC_BIN" \
        "cxx=$CXX_BIN" \
        "glibc=$GLIBC_DIR" \
        "sysroot=$CROSS_SYSROOT" \
        "stage=$SYSROOT_LIBDIR" \
        "protobuf_inc=$PROTOBUF_INCLUDE_OVERRIDE" \
        "protoc=$PROTOC_EXEC" \
        "cflags=$CFLAGS_EXTRA" \
        "cxxflags=$CXXFLAGS_EXTRA" \
        "ldflags=$LDFLAGS_EXTRA" \
        "toolchain=$(sha256sum "$CROSS_TOOLCHAIN" 2>/dev/null | cut -d' ' -f1)"
}

prepare_build_dir() {
    local builddir="$1"
    local sigfile="$builddir/.adb-build-signature"
    local sig
    sig="$(build_signature)"

    if [[ -d "$builddir" ]]; then
        if [[ -f "$sigfile" && "$(cat "$sigfile")" == "$sig" ]]; then
            info "构建目录签名一致，复用缓存：$builddir"
            return 0
        fi
        warn "编译器/sysroot/链接方式已变化，清理旧构建缓存：$builddir"
        rm -rf "$builddir"
    fi
    mkdir -p "$builddir"
}

build_adb() {
    if (( USE_LATEST )); then
        ADB_VERSION="$(github_latest_version)" || die "无法查询 GitHub 最新版本"
        info "GitHub 最新版本：$ADB_VERSION"
    fi
    [[ "$ADB_VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || die "版本号格式不合法: $ADB_VERSION"

    if (( CROSS )); then
        prepare_cross_sysroot
        if [[ -z "$SYSROOT_LIBDIR" ]]; then
            LDFLAGS_EXTRA+=" -L$CROSS_SYSROOT/usr/lib/$TARGET_ARCH-linux-gnu"
            LDFLAGS_EXTRA+=" -Wl,-rpath-link,$CROSS_SYSROOT/usr/lib/$TARGET_ARCH-linux-gnu"
        fi
        log "交叉编译 adb $ADB_VERSION → $TARGET_ARCH（源码：nmeum/android-tools）"
    else
        log "编译 adb $ADB_VERSION（源码：nmeum/android-tools）"
    fi
    setup_glibc
    setup_static
    (( STATIC_LINK )) && log "链接方式：静态（static）" || log "链接方式：动态（shared）"

    local src="$ADB_DIR/android-tools-$ADB_VERSION.tar.xz"
    local vendor="$ADB_DIR/android-tools-$ADB_VERSION-vendor.tar.xz"
    local base="https://github.com/nmeum/android-tools/releases/download/$ADB_VERSION"
    adb_checksums "$ADB_VERSION"
    [[ -n "$ADB_SRC_SHA" ]] || warn "未收录 $ADB_VERSION 的校验值，将跳过 SHA256 校验"

    fetch "$base/android-tools-$ADB_VERSION.tar.xz" "$src" auto || \
        die "下载失败：$base/android-tools-$ADB_VERSION.tar.xz（版本是否存在？）"
    verify_sha256 "$src" "$ADB_SRC_SHA" || die "源码校验失败"

    # 只有较新的版本单独提供 vendor 包（主要包含 Rust/mDNS 依赖）；
    # 旧版本的主源码包已自带依赖，没有这个包也能编译。
    local have_vendor=0
    if fetch "$base/android-tools-$ADB_VERSION-vendor.tar.xz" "$vendor" auto; then
        have_vendor=1
        verify_sha256 "$vendor" "$ADB_VENDOR_SHA" || die "依赖源码校验失败"
    else
        warn "$ADB_VERSION 没有独立的 vendor 包，使用主源码包内置的依赖"
        rm -f "${vendor}.part"
    fi

    local work="$ADB_DIR/src-$ADB_VERSION"
    if [[ ! -f "$work/.extracted" ]]; then
        info "解压源码到 $work"
        mkdir -p "$work"
        # 主源码包顶层目录为 android-tools-<ver>/
        tar xf "$src" -C "$work" --strip-components=1 || die "主源码解压失败"
        if (( have_vendor )); then
            # 依赖包内路径本身就是 vendor/...，直接解压到源码根目录
            tar xf "$vendor" -C "$work" || die "依赖源码解压失败"
        fi
        touch "$work/.extracted"
    else
        info "源码已解压，跳过：$work"
    fi

    patch_vendor_sources "$work"

    local builddir="$work/$BUILD_SUBDIR"
    prepare_build_dir "$builddir"
    local -a cmake_args=(
        -S "$work" -B "$builddir" -G Ninja
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
        -DANDROID_TOOLS_USE_BUNDLED_FMT=ON
        -DANDROID_TOOLS_USE_BUNDLED_LIBUSB=ON
    )

    if (( CROSS )); then
        cmake_args+=(
            -DCMAKE_TOOLCHAIN_FILE="$CROSS_TOOLCHAIN"
            -DProtobuf_PROTOC_EXECUTABLE="${PROTOC_EXEC:-$(command -v protoc)}"
            -DCMAKE_SKIP_RPATH=ON
        )
        if [[ -n "$SYSROOT_LIBDIR" ]]; then
            # 使用 staging 中的第三方库，避免 CMake 误用目标 rootfs 的 glibc/gcc 运行时
            local pinc="$SYSROOT_INCDIR"
            [[ -n "$PROTOBUF_INCLUDE_OVERRIDE" ]] && pinc="$PROTOBUF_INCLUDE_OVERRIDE"
            cmake_args+=(-DProtobuf_INCLUDE_DIR="$pinc")
            if (( ! STATIC_LINK )); then
                cmake_args+=(-DProtobuf_LIBRARY="$SYSROOT_LIBDIR/libprotobuf.so")
            fi
        fi
    else
        [[ -n "$CC_BIN" ]]  && cmake_args+=(-DCMAKE_C_COMPILER="$CC_BIN")
        [[ -n "$CXX_BIN" ]] && cmake_args+=(-DCMAKE_CXX_COMPILER="$CXX_BIN")
    fi

    [[ -n "$CFLAGS_EXTRA" ]]   && cmake_args+=(-DCMAKE_C_FLAGS="$CFLAGS_EXTRA")
    [[ -n "$CXXFLAGS_EXTRA" ]] && cmake_args+=(-DCMAKE_CXX_FLAGS="$CXXFLAGS_EXTRA")
    [[ -n "$LDFLAGS_EXTRA" ]]  && cmake_args+=(-DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_EXTRA")

    if (( STATIC_LINK )); then
        cmake_args+=(
            -DCMAKE_PROJECT_INCLUDE="$STATIC_PRELUDE"
            -DProtobuf_LIBRARY="$PROTOBUF_STATIC"
            -DANDROID_TOOLS_LIBUSB_ENABLE_UDEV=OFF
            -DANDROID_TOOLS_ADB_ENABLE_MDNS=OFF
        )
        warn "静态链接已关闭 udev（系统通常不提供 libudev.a）与 mDNS（Rust 静态链接需要 libgcc_s）"
    else
        cmake_args+=(-DANDROID_TOOLS_LIBUSB_ENABLE_UDEV=ON)
        if (( CROSS )); then
            cmake_args+=(-DANDROID_TOOLS_ADB_ENABLE_MDNS=OFF)
            warn "交叉编译不启用 mDNS（缺少 aarch64 的 Rust 标准库），无线调试自动发现不可用"
        elif (( have_vendor )) && command -v rustc >/dev/null 2>&1 && \
           [[ -f /usr/lib/x86_64-linux-gnu/cmake/Corrosion/CorrosionConfig.cmake || \
              -f /usr/share/cmake/Corrosion/CorrosionConfig.cmake ]]; then
            cmake_args+=(-DANDROID_TOOLS_ADB_ENABLE_MDNS=ON)
        else
            warn "未启用 mDNS（缺少 Rust/Corrosion 或该版本无 vendor 包），无线调试自动发现不可用"
            cmake_args+=(-DANDROID_TOOLS_ADB_ENABLE_MDNS=OFF)
        fi
    fi

    info "配置 CMake（构建目录：$builddir）"
    cmake "${cmake_args[@]}" || die "CMake 配置失败"
    build_signature > "$builddir/.adb-build-signature"
    info "编译 adb（$JOBS 个并行任务）"
    cmake --build "$builddir" --target adb --parallel "$JOBS" || die "adb 编译失败"

    BUILT_ADB="$builddir/vendor/adb"
    [[ -x "$BUILT_ADB" ]] || die "编译完成但未找到 adb 可执行文件"
    info "编译产物：$BUILT_ADB"
    if (( CROSS )); then
        verify_cross_binary "$BUILT_ADB"
    fi
}

# ---------------------------------------------------------------------------
# 安装到本机（直接拷贝）
# ---------------------------------------------------------------------------
install_local() {
    local bin="$1" ver="$2" suffix="$LINK_SUFFIX"

    if (( CROSS )); then
        local dest="$INSTALL_PREFIX/versions/$ver/$TARGET_ARCH/adb$suffix"
        log "归档 $TARGET_ARCH 版本到本机（不覆盖本机 adb）"
        $SUDO install -Dm755 "$bin" "$dest" || die "归档 adb 失败"
        info "已归档：$dest"
        info "要安装到 aarch64 主机，请使用 --host <主机>"
        return 0
    fi

    log "安装到本机（$INSTALL_PREFIX）"
    $SUDO install -Dm755 "$bin" "$INSTALL_PREFIX/versions/$ver/adb$suffix" || die "归档 adb 失败"
    $SUDO install -Dm755 "$bin" "$INSTALL_PREFIX/bin/adb" || die "安装 adb 失败"

    if [[ -e /usr/local/bin/adb && ! -L /usr/local/bin/adb ]]; then
        $SUDO mv /usr/local/bin/adb "/usr/local/bin/adb.bak.$(date +%s)"
        warn "已备份原有的 /usr/local/bin/adb"
    fi
    $SUDO ln -sfn "$INSTALL_PREFIX/bin/adb" /usr/local/bin/adb

    if [[ -f "$ADB_DIR/src-$ver/vendor/adb/adb.bash" ]]; then
        $SUDO install -Dm644 "$ADB_DIR/src-$ver/vendor/adb/adb.bash" \
            /usr/share/bash-completion/completions/adb || true
    fi

    log "安装结果"
    "$INSTALL_PREFIX/versions/$ver/adb$suffix" version
}

# ---------------------------------------------------------------------------
# 安装到远程主机（SSH）
# ---------------------------------------------------------------------------
install_remote() {
    local bin="$1" ver="$2" host="$TARGET_HOST" suffix="$LINK_SUFFIX"
    command -v ssh >/dev/null 2>&1 || die "本机没有 ssh 客户端"

    local -a ssh_cmd=(ssh -o ConnectTimeout=10)
    [[ -n "$SSH_PORT" ]] && ssh_cmd+=(-p "$SSH_PORT")

    log "安装到远程主机 $host"
    info "测试 SSH 连接"
    "${ssh_cmd[@]}" "$host" true || \
        die "无法通过 SSH 连接 $host（请先配置 SSH 免密登录或 ssh-agent）"

    # 架构校验，避免把 aarch64 的 adb 装到 x86_64 主机上（或反之）
    local remote_arch remote_norm
    remote_arch="$("${ssh_cmd[@]}" "$host" 'uname -m' 2>/dev/null || true)"
    remote_norm="$(map_arch "$remote_arch")"
    if [[ -n "$remote_norm" ]]; then
        info "远端架构：$remote_norm"
        [[ "$remote_norm" == "$TARGET_ARCH" ]] || \
            die "远端架构 $remote_norm 与编译目标 $TARGET_ARCH 不一致"
    else
        warn "无法识别远端架构（$remote_arch），跳过架构校验"
    fi

    local remote_tmp="/tmp/adb-$ver-$TARGET_ARCH$suffix-$$"
    info "上传二进制到 $host:$remote_tmp"
    "${ssh_cmd[@]}" "$host" "cat > '$remote_tmp' && chmod 700 '$remote_tmp'" < "$bin" || \
        die "上传 adb 到 $host 失败"

    # 远端脚本：安装、备份旧文件、更新软链、清理临时文件、验证
    local remote_script
    remote_script=$(cat <<EOF
set -e
SUDO=""
if [ "\$(id -u)" -ne 0 ]; then
    SUDO="sudo"
    \$SUDO -n true 2>/dev/null || { echo "远端 sudo 需要密码，请配置免密 sudo" >&2; exit 1; }
fi
\$SUDO install -Dm755 '$remote_tmp' '$INSTALL_PREFIX/versions/$ver/adb$suffix'
\$SUDO install -Dm755 '$remote_tmp' '$INSTALL_PREFIX/bin/adb'
if [ -e /usr/local/bin/adb ] && [ ! -L /usr/local/bin/adb ]; then
    \$SUDO mv /usr/local/bin/adb "/usr/local/bin/adb.bak.\$(date +%s)"
fi
\$SUDO ln -sfn '$INSTALL_PREFIX/bin/adb' /usr/local/bin/adb
rm -f '$remote_tmp'
'$INSTALL_PREFIX/versions/$ver/adb$suffix' version
EOF
)

    info "在 $host 上执行安装"
    local hint="请确认远端有免密 sudo 权限"
    (( ! STATIC_LINK )) && \
        hint+="；若缺少运行库，请安装 libprotobuf32t64 libbrotli1 liblz4-1 libzstd1 libudev1 zlib1g"
    "${ssh_cmd[@]}" "$host" bash -s <<<"$remote_script" || die "远程安装失败（$hint）"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if (( LIST_VERSIONS )); then
    list_versions
    exit 0
fi

install_deps

# 默认交叉编译器由 install_deps 安装，安装后再校验一次
if (( CROSS )); then
    (( CC_USER_SPECIFIED ))  || check_compiler "$CC_BIN" "C"
    (( CXX_USER_SPECIFIED )) || check_compiler "$CXX_BIN" "C++"
fi

build_adb

if (( DO_INSTALL )); then
    if [[ -n "$TARGET_HOST" ]]; then
        install_remote "$BUILT_ADB" "$ADB_VERSION"
    else
        install_local "$BUILT_ADB" "$ADB_VERSION"
    fi
else
    log "已跳过安装（--no-install）"
    info "编译产物：$BUILT_ADB"
fi

log "完成"
if (( CROSS )); then
    info "目标架构：$TARGET_ARCH（交叉编译，glibc）"
fi
if (( STATIC_LINK )); then
    info "链接方式：静态（static）"
else
    info "链接方式：动态（shared）"
fi
[[ -n "$GLIBC_DIR" ]] && info "glibc：$GLIBC_DIR"
if (( DO_INSTALL )); then
    if [[ -n "$TARGET_HOST" ]]; then
        info "安装目标：$TARGET_HOST:$INSTALL_PREFIX/bin/adb"
        info "SSH 端口：${SSH_PORT:-22}"
    elif (( CROSS )); then
        info "已归档：$INSTALL_PREFIX/versions/$ADB_VERSION/$TARGET_ARCH/adb$LINK_SUFFIX"
    else
        installed="$INSTALL_PREFIX/versions/$ADB_VERSION/adb$LINK_SUFFIX"
        info "adb 版本：$("$installed" version 2>/dev/null | sed -n '2p' || echo "$ADB_VERSION")"
        info "已安装：$installed"
        in_path="$(readlink -f "$(command -v adb 2>/dev/null || echo "")" 2>/dev/null || true)"
        if [[ -n "$in_path" && "$in_path" != "$(readlink -f "$installed")" ]]; then
            info "当前使用：$in_path"
            warn "注意：PATH 中优先的 adb 不是刚安装的版本，请检查 PATH 顺序"
        else
            info "当前使用：$in_path"
        fi
    fi
else
    info "未安装，编译产物保留在：$BUILT_ADB"
fi
info "源码与压缩包保留在：$ADB_DIR"
(( CROSS )) && info "交叉编译 sysroot：$CROSS_SYSROOT"
info "日志：$LOG_FILE"
