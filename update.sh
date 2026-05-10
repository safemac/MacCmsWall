#!/usr/bin/env bash
# MacCmsWall 更新脚本
# 兼容：CentOS / Debian / Ubuntu

set -u
set -o pipefail

PLUGIN_NAME="MacCmsWall"
PANEL_ROOT="/www/server/panel"
PLUGIN_DIR="${PANEL_ROOT}/plugin/${PLUGIN_NAME}"
REPO_URL="${MACCMSWALL_REPO:-https://github.com/safemac/MacCmsWall.git}"
REPO_BRANCH="${MACCMSWALL_BRANCH:-main}"
WORK_DIR=""
SOURCE_DIR=""

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}" >/dev/null 2>&1 || true
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 用户执行更新"
    fi
}

fetch_source() {
    WORK_DIR="$(mktemp -d /tmp/maccmswall-update.XXXXXX)"

    if command -v git >/dev/null 2>&1; then
        log "拉取更新源码: ${REPO_URL} (${REPO_BRANCH})"
        git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${WORK_DIR}/src" >/dev/null 2>&1 || die "克隆更新源码失败"
        SOURCE_DIR="${WORK_DIR}/src"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        die "缺少 git 和 curl，无法拉取更新"
    fi

    local tar_url="${REPO_URL%.git}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    log "通过压缩包下载更新源码: ${tar_url}"
    curl -fsSL "${tar_url}" -o "${WORK_DIR}/src.tar.gz" || die "下载更新压缩包失败"
    mkdir -p "${WORK_DIR}/unpack"
    tar -xzf "${WORK_DIR}/src.tar.gz" -C "${WORK_DIR}/unpack" || die "解压更新压缩包失败"

    local first_dir
    first_dir="$(find "${WORK_DIR}/unpack" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -n "${first_dir}" ] || die "未找到更新源码目录"

    mkdir -p "${WORK_DIR}/src"
    cp -a "${first_dir}/." "${WORK_DIR}/src/" || die "拷贝更新源码失败"
    SOURCE_DIR="${WORK_DIR}/src"
}

run_install() {
    [ -f "${SOURCE_DIR}/install.sh" ] || die "更新包缺少 install.sh"

    # 更新统一复用 install.sh，依赖其内置的升级保留逻辑。
    MACCMSWALL_LOCAL_DIR="${SOURCE_DIR}" \
    MACCMSWALL_REPO="${REPO_URL}" \
    MACCMSWALL_BRANCH="${REPO_BRANCH}" \
    bash "${SOURCE_DIR}/install.sh"
}

main() {
    trap cleanup EXIT

    require_root

    if [ ! -d "${PANEL_ROOT}" ]; then
        die "未检测到面板目录 ${PANEL_ROOT}"
    fi

    if [ ! -d "${PLUGIN_DIR}" ]; then
        log "插件未安装，转为首次安装流程"
    fi

    fetch_source
    run_install

    log "更新完成"
}

main "$@"
