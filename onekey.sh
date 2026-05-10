#!/usr/bin/env bash
# MacCmsWall 一键智能入口脚本
# 默认行为：
# 1) 未安装插件 -> 自动安装
# 2) 已安装插件 -> 自动更新
# 3) 可通过环境变量指定卸载

set -u
set -o pipefail

PLUGIN_NAME="MacCmsWall"
PANEL_ROOT="/www/server/panel"
PLUGIN_DIR="${PANEL_ROOT}/plugin/${PLUGIN_NAME}"
REPO_URL="${MACCMSWALL_REPO:-https://github.com/safemac/MacCmsWall.git}"
REPO_BRANCH="${MACCMSWALL_BRANCH:-main}"
RAW_BASE="${MACCMSWALL_RAW_BASE:-https://raw.githubusercontent.com/safemac/MacCmsWall/${REPO_BRANCH}}"
ACTION="${MACCMSWALL_ACTION:-auto}"
WORK_DIR=""

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
        die "请使用 root 用户执行"
    fi
}

need_downloader() {
    if command -v curl >/dev/null 2>&1; then
        echo "curl"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        echo "wget"
        return 0
    fi

    return 1
}

download_file() {
    local url="$1"
    local output="$2"
    local downloader

    downloader="$(need_downloader || true)"
    [ -n "${downloader}" ] || die "缺少 curl/wget，无法下载脚本"

    if [ "${downloader}" = "curl" ]; then
        curl -fsSL "${url}" -o "${output}" || return 1
    else
        wget -qO "${output}" "${url}" || return 1
    fi

    return 0
}

resolve_action() {
    case "${ACTION}" in
        auto|install|update|uninstall)
            ;;
        *)
            die "无效操作: ${ACTION}，仅支持 auto/install/update/uninstall"
            ;;
    esac

    if [ "${ACTION}" = "auto" ]; then
        if [ -d "${PLUGIN_DIR}" ] && [ -f "${PLUGIN_DIR}/main.py" ]; then
            ACTION="update"
        else
            ACTION="install"
        fi
    fi

    # 未安装时请求更新，自动转首次安装。
    if [ "${ACTION}" = "update" ] && [ ! -d "${PLUGIN_DIR}" ]; then
        log "检测到插件未安装，自动切换为 install"
        ACTION="install"
    fi

    # 未安装时请求卸载，直接提示并结束。
    if [ "${ACTION}" = "uninstall" ] && [ ! -d "${PLUGIN_DIR}" ]; then
        log "插件未安装，无需卸载"
        exit 0
    fi
}

run_local_if_exists() {
    local script_name="$1"
    local local_script="${PLUGIN_DIR}/${script_name}"

    if [ -x "${local_script}" ]; then
        MACCMSWALL_REPO="${REPO_URL}" MACCMSWALL_BRANCH="${REPO_BRANCH}" bash "${local_script}"
        return $?
    fi

    return 1
}

run_remote_script() {
    local script_name="$1"
    local remote_url="${RAW_BASE}/${script_name}"
    local script_file="${WORK_DIR}/${script_name}"

    if ! download_file "${remote_url}" "${script_file}"; then
        die "下载脚本失败: ${remote_url}"
    fi

    chmod +x "${script_file}" >/dev/null 2>&1 || true
    MACCMSWALL_REPO="${REPO_URL}" MACCMSWALL_BRANCH="${REPO_BRANCH}" bash "${script_file}"
}

main() {
    trap cleanup EXIT

    require_root

    if [ ! -d "${PANEL_ROOT}" ]; then
        die "未检测到面板目录 ${PANEL_ROOT}"
    fi

    resolve_action
    WORK_DIR="$(mktemp -d /tmp/maccmswall-onekey.XXXXXX)"

    case "${ACTION}" in
        install)
            log "智能模式：执行安装"
            run_remote_script "install.sh"
            ;;
        update)
            log "智能模式：执行更新"
            if ! run_local_if_exists "update.sh"; then
                run_remote_script "update.sh"
            fi
            ;;
        uninstall)
            log "智能模式：执行卸载"
            if ! run_local_if_exists "uninstall.sh"; then
                run_remote_script "uninstall.sh"
            fi
            ;;
    esac

    log "一键处理完成"
}

main "$@"
