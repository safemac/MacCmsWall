#!/usr/bin/env bash
# MacCmsWall 分发包构建脚本
# 产物：dist/MacCmsWall-vX.Y.Z.tar.gz 和 dist/MacCmsWall-vX.Y.Z.zip

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
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

get_version() {
    local info_file="${ROOT_DIR}/panel/info.json"
    [ -f "${info_file}" ] || die "缺少 ${info_file}"

    local version
    version="$(grep -E '"version"[[:space:]]*:' "${info_file}" | head -n 1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    [ -n "${version}" ] || die "无法从 info.json 解析版本号"

    printf "%s" "${version}"
}

build_release() {
    local version package_name stage_root stage_dir
    version="$(get_version)"
    package_name="MacCmsWall-v${version}"

    mkdir -p "${DIST_DIR}"
    WORK_DIR="$(mktemp -d /tmp/maccmswall-release.XXXXXX)"

    stage_root="${WORK_DIR}/stage"
    stage_dir="${stage_root}/MacCmsWall"
    mkdir -p "${stage_dir}"

    # 分发包直接输出 BT/aaPanel 插件根目录结构。
    cp -a "${ROOT_DIR}/panel/." "${stage_dir}/"
    cp -a "${ROOT_DIR}/scripts" "${stage_dir}/scripts"
    cp -a "${ROOT_DIR}/database" "${stage_dir}/database"
    cp -a "${ROOT_DIR}/logs" "${stage_dir}/logs"

    for f in install.sh uninstall.sh update.sh onekey.sh README.md; do
        [ -f "${ROOT_DIR}/${f}" ] || die "缺少 ${f}"
        cp -a "${ROOT_DIR}/${f}" "${stage_dir}/${f}"
    done

    (cd "${stage_root}" && tar -czf "${DIST_DIR}/${package_name}.tar.gz" "MacCmsWall") || die "生成 tar.gz 失败"

    if command -v zip >/dev/null 2>&1; then
        (cd "${stage_root}" && zip -qr "${DIST_DIR}/${package_name}.zip" "MacCmsWall") || die "生成 zip 失败"
    else
        log "未检测到 zip 命令，跳过 zip 产物"
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        (
            cd "${DIST_DIR}" || exit 1
            sha256sum "${package_name}.tar.gz" > "${package_name}.sha256"
            if [ -f "${package_name}.zip" ]; then
                sha256sum "${package_name}.zip" >> "${package_name}.sha256"
            fi
        ) || die "生成校验文件失败"
    fi

    log "分发构建完成: ${DIST_DIR}"
}

main() {
    trap cleanup EXIT
    build_release
}

main "$@"
