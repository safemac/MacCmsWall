#!/usr/bin/env bash
# MacCmsWall 一键智能入口脚本
# 默认行为：
# 1) 未安装插件 -> 自动安装
# 2) 已安装插件 -> 自动更新
# 3) 可通过环境变量指定卸载

set -u
set -o pipefail

PLUGIN_NAME="maccmswall"
PANEL_ROOT="/www/server/panel"
PLUGIN_DIR_PRIMARY="${PANEL_ROOT}/plugin/${PLUGIN_NAME}"
PLUGIN_DIR_ALT="${PANEL_ROOT}/plugin/MacCmsWall"
PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
REPO_URL="${MACCMSWALL_REPO:-https://github.com/safemac/MacCmsWall.git}"
REPO_BRANCH="${MACCMSWALL_BRANCH:-main}"
RAW_BASE="${MACCMSWALL_RAW_BASE:-https://raw.githubusercontent.com/safemac/MacCmsWall/${REPO_BRANCH}}"
ACTION="${MACCMSWALL_ACTION:-auto}"
CHECKSUM_FILE="${MACCMSWALL_CHECKSUM_FILE:-checksums.md5}"
WORK_DIR=""
REMOTE_CHECKSUM_PATH=""

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

md5_of_file() {
    local file_path="$1"

    if command -v md5sum >/dev/null 2>&1; then
        md5sum "${file_path}" | awk '{print $1}'
        return 0
    fi

    if command -v openssl >/dev/null 2>&1; then
        openssl md5 "${file_path}" | awk '{print $NF}'
        return 0
    fi

    if command -v md5 >/dev/null 2>&1; then
        md5 -q "${file_path}"
        return 0
    fi

    die "系统缺少 md5sum/openssl/md5，无法执行完整性校验"
}

expected_md5_from_manifest() {
    local manifest_file="$1"
    local target_name="$2"

    awk -v n="${target_name}" '$2==n{print $1; exit}' "${manifest_file}"
}

verify_file_md5() {
    local manifest_file="$1"
    local file_path="$2"
    local short_name="$3"
    local expected actual

    [ -f "${manifest_file}" ] || die "缺少校验清单: ${manifest_file}"
    [ -f "${file_path}" ] || die "缺少待校验文件: ${file_path}"

    expected="$(expected_md5_from_manifest "${manifest_file}" "${short_name}" | tr 'A-Z' 'a-z')"
    [ -n "${expected}" ] || die "校验清单中缺少 ${short_name} 的 MD5"

    actual="$(md5_of_file "${file_path}" | tr 'A-Z' 'a-z')"
    [ -n "${actual}" ] || die "计算 ${short_name} MD5 失败"

    if [ "${expected}" != "${actual}" ]; then
        die "检测到脚本篡改: ${short_name}，拒绝执行"
    fi
}

prepare_remote_checksum_manifest() {
    local remote_url

    if [ -n "${REMOTE_CHECKSUM_PATH}" ] && [ -f "${REMOTE_CHECKSUM_PATH}" ]; then
        return 0
    fi

    REMOTE_CHECKSUM_PATH="${WORK_DIR}/${CHECKSUM_FILE}"
    remote_url="${RAW_BASE}/${CHECKSUM_FILE}"

    if ! download_file "${remote_url}" "${REMOTE_CHECKSUM_PATH}"; then
        die "下载校验清单失败: ${remote_url}"
    fi
}

detect_installed_plugin_dir() {
    if [ -d "${PLUGIN_DIR_PRIMARY}" ] && [ -f "${PLUGIN_DIR_PRIMARY}/main.py" ]; then
        PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
        return 0
    fi

    if [ -d "${PLUGIN_DIR_ALT}" ] && [ -f "${PLUGIN_DIR_ALT}/main.py" ]; then
        PLUGIN_DIR="${PLUGIN_DIR_ALT}"
        return 0
    fi

    PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
    return 1
}

resolve_action() {
    local has_install=0

    if detect_installed_plugin_dir; then
        has_install=1
    fi

    case "${ACTION}" in
        auto|install|update|uninstall)
            ;;
        *)
            die "无效操作: ${ACTION}，仅支持 auto/install/update/uninstall"
            ;;
    esac

    if [ "${ACTION}" = "auto" ]; then
        if [ "${has_install}" -eq 1 ]; then
            ACTION="update"
        else
            ACTION="install"
        fi
    fi

    # 未安装时请求更新，自动转首次安装。
    if [ "${ACTION}" = "update" ] && [ "${has_install}" -eq 0 ]; then
        log "检测到插件未安装，自动切换为 install"
        ACTION="install"
    fi

    # 未安装时请求卸载，直接提示并结束。
    if [ "${ACTION}" = "uninstall" ] && [ "${has_install}" -eq 0 ]; then
        log "插件未安装，无需卸载"
        exit 0
    fi
}

run_local_if_exists() {
    local script_name="$1"
    local local_script="${PLUGIN_DIR}/${script_name}"
    local local_manifest="${PLUGIN_DIR}/${CHECKSUM_FILE}"

    if [ -x "${local_script}" ]; then
        if [ ! -f "${local_manifest}" ]; then
            log "本地缺少校验清单，改用远程已校验脚本: ${script_name}"
            return 1
        fi

        verify_file_md5 "${local_manifest}" "${local_script}" "${script_name}"
        MACCMSWALL_REPO="${REPO_URL}" MACCMSWALL_BRANCH="${REPO_BRANCH}" bash "${local_script}"
        return $?
    fi

    return 1
}

run_remote_script() {
    local script_name="$1"
    local remote_url="${RAW_BASE}/${script_name}"
    local script_file="${WORK_DIR}/${script_name}"

    prepare_remote_checksum_manifest

    if ! download_file "${remote_url}" "${script_file}"; then
        die "下载脚本失败: ${remote_url}"
    fi

    verify_file_md5 "${REMOTE_CHECKSUM_PATH}" "${script_file}" "${script_name}"

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
