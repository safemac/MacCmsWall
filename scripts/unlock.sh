#!/usr/bin/env bash
# 根据数据库索引对网站文件执行 chattr -i。

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

SITE_ID="${1:-}"
DB_PATH="${2:-}"
LOG_FILE="${3:-}"

if [ -z "${SITE_ID}" ] || [ -z "${DB_PATH}" ]; then
    echo "用法: unlock.sh <site_id> <db_path> [log_file]" >&2
    exit 1
fi

if ! [[ "${SITE_ID}" =~ ^[0-9]+$ ]]; then
    echo "site_id 必须为数字" >&2
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

unlocked_count=0
miss_count=0
fail_count=0
now="$(timestamp)"

while IFS=$'\t' read -r file_id file_path; do
    if [ -z "${file_id}" ] || [ -z "${file_path}" ]; then
        continue
    fi

    if [ ! -e "${file_path}" ]; then
        miss_count=$((miss_count + 1))
        sqlite3 "${DB_PATH}" "UPDATE files SET locked=0,updated_at=${now} WHERE id=${file_id};" >/dev/null 2>&1 || true
        continue
    fi

    if chattr -i -- "${file_path}" >/dev/null 2>&1; then
        unlocked_count=$((unlocked_count + 1))
        sqlite3 "${DB_PATH}" "UPDATE files SET locked=0,updated_at=${now} WHERE id=${file_id};" >/dev/null 2>&1 || true
    else
        fail_count=$((fail_count + 1))
        log_msg "${LOG_FILE}" "WARN" "解锁失败 file=${file_path}"
    fi
done < <(sqlite3 -batch -noheader -separator $'\t' "${DB_PATH}" "SELECT id,file_path FROM files WHERE site_id=${SITE_ID} AND locked=1;")

log_msg "${LOG_FILE}" "INFO" "解锁完成 site_id=${SITE_ID} unlocked_count=${unlocked_count} miss_count=${miss_count} fail_count=${fail_count}"

printf "UNLOCKED_COUNT=%s\n" "${unlocked_count}"
printf "MISS_COUNT=%s\n" "${miss_count}"
printf "FAIL_COUNT=%s\n" "${fail_count}"

if [ "${fail_count}" -gt 0 ]; then
    exit 3
fi

exit 0
