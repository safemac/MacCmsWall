#!/usr/bin/env bash
# MacCmsWall 通用函数库
# 说明：为扫描、加锁、解锁脚本提供统一日志、依赖检查与路径规则处理。

set -u
set -o pipefail

# 返回 Unix 时间戳。
timestamp() {
    date +%s
}

# 返回可读时间。
human_time() {
    date "+%Y-%m-%d %H:%M:%S"
}

# 统一写日志：优先写入日志文件，同时输出到标准输出供上层采集。
log_msg() {
    local log_file="${1:-}"
    local level="${2:-INFO}"
    local message="${3:-}"
    local line
    line="$(human_time) [${level}] ${message}"

    if [ -n "${log_file}" ]; then
        mkdir -p "$(dirname "${log_file}")" >/dev/null 2>&1 || true
        printf "%s\n" "${line}" >> "${log_file}" 2>/dev/null || true
    fi

    printf "%s\n" "${line}"
}

# 判断命令是否存在。
need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 规范化路径，避免软链接和相对路径导致重复记录。
normalize_path() {
    local target="${1:-}"

    if [ -z "${target}" ]; then
        return 1
    fi

    if [ -d "${target}" ]; then
        (cd "${target}" 2>/dev/null && pwd -P)
        return $?
    fi

    if [ -f "${target}" ]; then
        local parent base
        parent="$(dirname "${target}")"
        base="$(basename "${target}")"
        (cd "${parent}" 2>/dev/null && printf "%s/%s\n" "$(pwd -P)" "${base}")
        return $?
    fi

    return 1
}

# MACCMS 模式排除规则：返回 0 表示该文件应跳过锁定或索引。
is_maccms_skip_path() {
    local file_path="${1:-}"
    local site_path="${2:-}"
    local rel

    if [ -z "${file_path}" ] || [ -z "${site_path}" ]; then
        return 1
    fi

    rel="${file_path#${site_path}}"
    rel="/${rel#/}"

    case "${rel}" in
        /runtime/*|/cache/*|/static/upload/*|/upload/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
