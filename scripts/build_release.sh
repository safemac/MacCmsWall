#!/usr/bin/env bash
# MacCmsWall 分发包构建脚本
# 产物：dist/MacCmsWall-vX.Y.Z.tar.gz 和 dist/MacCmsWall-vX.Y.Z.zip

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
SKILL_FILE="${SCRIPT_DIR}/release_skill.sh"
WORK_DIR=""

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

[ -f "${SKILL_FILE}" ] || die "缺少 ${SKILL_FILE}"
# shellcheck source=/dev/null
source "${SKILL_FILE}"

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
    local script_md5_file tar_file zip_file artifact_md5_file artifact_sha256_file
    version="$(get_version)"
    package_name="MacCmsWall-v${version}"
    script_md5_file="${ROOT_DIR}/checksums.md5"
    artifact_md5_file="${DIST_DIR}/${package_name}.md5"
    artifact_sha256_file="${DIST_DIR}/${package_name}.sha256"

    release_skill_generate_script_md5_manifest "${ROOT_DIR}" "${script_md5_file}" || die "生成脚本 MD5 清单失败"

    mkdir -p "${DIST_DIR}"
    WORK_DIR="$(mktemp -d /tmp/maccmswall-release.XXXXXX)"

    stage_root="${WORK_DIR}/stage"
    stage_dir="${stage_root}/maccmswall"
    mkdir -p "${stage_dir}"

    # 分发包直接输出 BT/aaPanel 插件根目录结构。
    cp -a "${ROOT_DIR}/panel/." "${stage_dir}/"
    cp -a "${ROOT_DIR}/scripts" "${stage_dir}/scripts"
    cp -a "${ROOT_DIR}/database" "${stage_dir}/database"
    cp -a "${ROOT_DIR}/logs" "${stage_dir}/logs"

    for f in install.sh uninstall.sh update.sh onekey.sh checksums.md5 README.md; do
        [ -f "${ROOT_DIR}/${f}" ] || die "缺少 ${f}"
        cp -a "${ROOT_DIR}/${f}" "${stage_dir}/${f}"
    done

    tar_file="${DIST_DIR}/${package_name}.tar.gz"
    zip_file="${DIST_DIR}/${package_name}.zip"

    (cd "${stage_root}" && tar -czf "${tar_file}" "maccmswall") || die "生成 tar.gz 失败"

    if command -v zip >/dev/null 2>&1; then
        (cd "${stage_root}" && zip -qr "${zip_file}" "maccmswall") || die "生成 zip 失败"
    else
        log "未检测到 zip 命令，跳过 zip 产物"
        zip_file=""
    fi

    if [ -n "${zip_file}" ] && [ -f "${zip_file}" ]; then
        release_skill_generate_artifact_md5 "${artifact_md5_file}" "${zip_file}" "${tar_file}" || die "生成产物 MD5 失败"
        release_skill_generate_artifact_sha256 "${artifact_sha256_file}" "${zip_file}" "${tar_file}" || die "生成产物 SHA256 失败"
    else
        release_skill_generate_artifact_md5 "${artifact_md5_file}" "${tar_file}" || die "生成产物 MD5 失败"
        release_skill_generate_artifact_sha256 "${artifact_sha256_file}" "${tar_file}" || die "生成产物 SHA256 失败"
    fi

    release_skill_update_readme_release_block "${ROOT_DIR}/README.md" "${version}" "${artifact_md5_file}" "${artifact_sha256_file}" || die "自动更新 README 失败"

    log "分发构建完成: ${DIST_DIR}"
}

main() {
    trap cleanup EXIT
    build_release
}

main "$@"
