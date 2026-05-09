#!/usr/bin/env bash
# 根据数据库索引对网站文件执行 chattr +i。

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

SITE_ID="${1:-}"
SITE_PATH_RAW="${2:-}"
MODE="${3:-strict}"
DB_PATH="${4:-}"
LOG_FILE="${5:-}"

if [ -z "${SITE_ID}" ] || [ -z "${SITE_PATH_RAW}" ] || [ -z "${DB_PATH}" ]; then
    echo "用法: lock.sh <site_id> <site_path> <mode> <db_path> [log_file]" >&2
    exit 1
fi

if ! [[ "${SITE_ID}" =~ ^[0-9]+$ ]]; then
    echo "site_id 必须为数字" >&2
    exit 1
fi

if [ "${MODE}" != "strict" ] && [ "${MODE}" != "maccms" ]; then
    echo "mode 仅支持 strict 或 maccms" >&2
    exit 1
fi

SITE_PATH="$(normalize_path "${SITE_PATH_RAW}" || true)"
if [ -z "${SITE_PATH}" ] || [ ! -d "${SITE_PATH}" ]; then
    echo "网站目录不存在: ${SITE_PATH_RAW}" >&2
    exit 1
fi

if ! need_cmd sqlite3; then
    echo "缺少 sqlite3 命令" >&2
    exit 1
fi

if ! need_cmd chattr; then
    echo "缺少 chattr 命令" >&2
    exit 1
fi

locked_count=0
skip_count=0
miss_count=0
fail_count=0
now="$(timestamp)"

while IFS=$'\t' read -r file_id file_path; do
    if [ -z "${file_id}" ] || [ -z "${file_path}" ]; then
        continue
    fi

    if [ "${MODE}" = "maccms" ] && is_maccms_skip_path "${file_path}" "${SITE_PATH}"; then
        skip_count=$((skip_count + 1))
        continue
    fi

    if [ ! -e "${file_path}" ]; then
        miss_count=$((miss_count + 1))
        continue
    fi

    if chattr +i -- "${file_path}" >/dev/null 2>&1; then
        locked_count=$((locked_count + 1))
        sqlite3 "${DB_PATH}" "UPDATE files SET locked=1,updated_at=${now} WHERE id=${file_id};" >/dev/null 2>&1 || true
    else
        fail_count=$((fail_count + 1))
        log_msg "${LOG_FILE}" "WARN" "加锁失败 file=${file_path}"
    fi
done < <(sqlite3 -batch -noheader -separator $'\t' "${DB_PATH}" "SELECT id,file_path FROM files WHERE site_id=${SITE_ID};")

log_msg "${LOG_FILE}" "INFO" "加锁完成 site_id=${SITE_ID} mode=${MODE} locked_count=${locked_count} skip_count=${skip_count} miss_count=${miss_count} fail_count=${fail_count}"

printf "LOCKED_COUNT=%s\n" "${locked_count}"
printf "SKIP_COUNT=%s\n" "${skip_count}"
printf "MISS_COUNT=%s\n" "${miss_count}"
printf "FAIL_COUNT=%s\n" "${fail_count}"

if [ "${fail_count}" -gt 0 ]; then
    exit 3
fi

exit 0
