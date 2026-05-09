#!/usr/bin/env bash
# 扫描网站文件并写入数据库文件索引。

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
    echo "用法: scan.sh <site_id> <site_path> <mode> <db_path> [log_file]" >&2
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

mkdir -p "$(dirname "${DB_PATH}")" >/dev/null 2>&1 || true

now="$(timestamp)"
scan_count=0
skip_count=0
error_count=0

# 先删除旧索引，保证数据库中的文件清单和当前站点一致。
if ! sqlite3 "${DB_PATH}" "DELETE FROM files WHERE site_id=${SITE_ID};" >/dev/null 2>&1; then
    echo "删除旧文件索引失败" >&2
    exit 1
fi

while IFS= read -r -d '' file_path; do
    if [ "${MODE}" = "maccms" ] && is_maccms_skip_path "${file_path}" "${SITE_PATH}"; then
        skip_count=$((skip_count + 1))
        continue
    fi

    escaped_path="$(printf "%s" "${file_path}" | sed "s/'/''/g")"
    sql="INSERT INTO files(site_id,file_path,locked,created_at,updated_at) VALUES(${SITE_ID},'${escaped_path}',0,${now},${now});"

    if sqlite3 "${DB_PATH}" "${sql}" >/dev/null 2>&1; then
        scan_count=$((scan_count + 1))
    else
        error_count=$((error_count + 1))
    fi
done < <(find "${SITE_PATH}" -type f -print0 2>/dev/null)

log_msg "${LOG_FILE}" "INFO" "扫描完成 site_id=${SITE_ID} mode=${MODE} scan_count=${scan_count} skip_count=${skip_count} error_count=${error_count}"

printf "SCAN_COUNT=%s\n" "${scan_count}"
printf "SKIP_COUNT=%s\n" "${skip_count}"
printf "ERROR_COUNT=%s\n" "${error_count}"

if [ "${error_count}" -gt 0 ]; then
    exit 2
fi

exit 0
