#!/usr/bin/env bash
# MacCmsWall 卸载脚本
# 兼容：CentOS / Debian / Ubuntu

set -u
set -o pipefail

PLUGIN_NAME="maccmswall"
PANEL_ROOT="/www/server/panel"
PLUGIN_DIR_PRIMARY="${PANEL_ROOT}/plugin/${PLUGIN_NAME}"
PLUGIN_DIR_ALT="${PANEL_ROOT}/plugin/MacCmsWall"
PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
DB_FILE="${PLUGIN_DIR}/database/maccmswall.db"
LOG_FILE="${PLUGIN_DIR}/logs/maccmswall.log"
UNLOCK_SCRIPT="${PLUGIN_DIR}/scripts/unlock.sh"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    log "WARN: $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 用户执行卸载"
    fi
}

select_plugin_dir() {
    if [ -d "${PLUGIN_DIR_PRIMARY}" ]; then
        PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
    elif [ -d "${PLUGIN_DIR_ALT}" ]; then
        PLUGIN_DIR="${PLUGIN_DIR_ALT}"
    else
        PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
    fi

    DB_FILE="${PLUGIN_DIR}/database/maccmswall.db"
    LOG_FILE="${PLUGIN_DIR}/logs/maccmswall.log"
    UNLOCK_SCRIPT="${PLUGIN_DIR}/scripts/unlock.sh"
}

unlock_all_sites() {
    # 卸载前尝试解锁所有已保护站点，避免遗留不可写文件。
    if [ ! -f "${DB_FILE}" ]; then
        warn "数据库不存在，跳过解锁步骤"
        return 0
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        warn "未安装 sqlite3，无法自动解锁"
        return 0
    fi

    if [ ! -x "${UNLOCK_SCRIPT}" ]; then
        warn "解锁脚本不存在，跳过解锁"
        return 0
    fi

    local site_ids
    site_ids="$(sqlite3 "${DB_FILE}" "SELECT id FROM sites WHERE status=1;" 2>/dev/null || true)"

    if [ -z "${site_ids}" ]; then
        log "无处于防护中的站点"
        return 0
    fi

    local sid
    for sid in ${site_ids}; do
        if bash "${UNLOCK_SCRIPT}" "${sid}" "${DB_FILE}" "${LOG_FILE}" >/dev/null 2>&1; then
            log "站点 ${sid} 解锁成功"
        else
            warn "站点 ${sid} 解锁失败，请手动检查文件属性"
        fi
    done
}

backup_data() {
    # 卸载前备份数据库和日志，便于后续审计。
    local backup_dir="/tmp/MacCmsWall_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "${backup_dir}"

    if [ -f "${DB_FILE}" ]; then
        cp -a "${DB_FILE}" "${backup_dir}/" || true
    fi

    if [ -f "${LOG_FILE}" ]; then
        cp -a "${LOG_FILE}" "${backup_dir}/" || true
    fi

    log "备份目录: ${backup_dir}"
}

restart_panel() {
    if [ -x "/etc/init.d/bt" ]; then
        /etc/init.d/bt restart >/dev/null 2>&1 && return 0
    fi

    if [ -x "/etc/init.d/aapanel" ]; then
        /etc/init.d/aapanel restart >/dev/null 2>&1 && return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart bt >/dev/null 2>&1 && return 0
        systemctl restart aapanel >/dev/null 2>&1 && return 0
    fi

    if command -v bt >/dev/null 2>&1; then
        bt restart >/dev/null 2>&1 && return 0
    fi

    return 1
}

main() {
    require_root
    select_plugin_dir

    if [ ! -d "${PLUGIN_DIR}" ]; then
        die "插件目录不存在: ${PLUGIN_DIR}"
    fi

    unlock_all_sites
    backup_data

    rm -rf "${PLUGIN_DIR}" || die "删除插件目录失败"

    # 清理兼容别名目录，避免卸载后残留死链接。
    rm -rf "${PLUGIN_DIR_PRIMARY}" >/dev/null 2>&1 || true
    rm -rf "${PLUGIN_DIR_ALT}" >/dev/null 2>&1 || true

    if restart_panel; then
        log "面板重启成功"
    else
        warn "未能自动重启面板，请手动执行: bt restart 或 /etc/init.d/aapanel restart"
    fi

    log "卸载完成"
}

main "$@"
