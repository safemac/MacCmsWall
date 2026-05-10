#!/usr/bin/env bash
# MacCmsWall 自动安装脚本
# 兼容：CentOS / Debian / Ubuntu

set -u
set -o pipefail

PLUGIN_NAME="maccmswall"
PLUGIN_TITLE="MacCmsWall"
PANEL_ROOT="/www/server/panel"
PLUGIN_DIR_PRIMARY="${PANEL_ROOT}/plugin/${PLUGIN_NAME}"
PLUGIN_DIR_ALT="${PANEL_ROOT}/plugin/MacCmsWall"
PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 可通过环境变量覆盖仓库地址和分支，便于私有仓库部署。
REPO_URL="${MACCMSWALL_REPO:-https://github.com/safemac/MacCmsWall.git}"
REPO_BRANCH="${MACCMSWALL_BRANCH:-main}"
CHECKSUM_FILE="${MACCMSWALL_CHECKSUM_FILE:-checksums.md5}"

PANEL_TYPE="bt"
PKG_MANAGER=""
WORK_DIR=""
SOURCE_DIR=""
BACKUP_DIR=""
BACKUP_ROOT="${MACCMSWALL_BACKUP_ROOT:-/www/backup/maccmswall}"

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

cleanup() {
    if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}" >/dev/null 2>&1 || true
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 用户执行安装"
    fi
}

# 兼容历史目录：若已安装在旧目录，后续操作直接复用。
select_plugin_dir() {
    if [ -d "${PLUGIN_DIR_PRIMARY}" ]; then
        PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
        return 0
    fi

    if [ -d "${PLUGIN_DIR_ALT}" ]; then

        PLUGIN_DIR="${PLUGIN_DIR_ALT}"
        log "检测到兼容目录: ${PLUGIN_DIR_ALT}"
        return 0
    fi

    PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
}


# 判断 install.sh 是否运行在面板插件目录中。
is_plugin_runtime_dir() {
    local real_dir
    real_dir="$(cd "${SCRIPT_DIR}" && pwd -P)"

    case "${real_dir}" in
        "${PANEL_ROOT}/plugin/"*)
            return 0
            ;;
    esac

    return 1
}

# 判断目录是否具备 BT 插件根结构。
is_plugin_root_layout() {
    local target_dir="$1"

    [ -f "${target_dir}/info.json" ] || return 1
    [ -f "${target_dir}/index.html" ] || return 1
    [ -d "${target_dir}/scripts" ] || return 1
    if [ ! -f "${target_dir}/maccmswall_main.py" ] && [ ! -f "${target_dir}/main.py" ]; then
        return 1
    fi

    return 0
}

ensure_backup_root() {
    if mkdir -p "${BACKUP_ROOT}" >/dev/null 2>&1; then
        return 0
    fi

    BACKUP_ROOT="/tmp/maccmswall-backups"
    mkdir -p "${BACKUP_ROOT}" >/dev/null 2>&1 || die "创建备份目录失败: ${BACKUP_ROOT}"
}

# 迁移旧目录和旧备份，避免插件目录出现重复副本导致重复识别。
normalize_plugin_layout() {
    local old_backup legacy_backup

    ensure_backup_root

    for old_backup in "${PANEL_ROOT}/plugin"/MacCmsWall_backup_* "${PANEL_ROOT}/plugin"/maccmswall_backup_*; do
        [ -d "${old_backup}" ] || continue
        mv "${old_backup}" "${BACKUP_ROOT}/$(basename "${old_backup}")" >/dev/null 2>&1 || true
    done

    if [ -L "${PLUGIN_DIR_ALT}" ]; then
        rm -f "${PLUGIN_DIR_ALT}" >/dev/null 2>&1 || true
    fi

    if [ ! -d "${PLUGIN_DIR_PRIMARY}" ] && [ -d "${PLUGIN_DIR_ALT}" ]; then
        mv "${PLUGIN_DIR_ALT}" "${PLUGIN_DIR_PRIMARY}" || die "迁移旧目录失败: ${PLUGIN_DIR_ALT} -> ${PLUGIN_DIR_PRIMARY}"
        log "已迁移旧目录到标准目录: ${PLUGIN_DIR_PRIMARY}"
    elif [ -d "${PLUGIN_DIR_PRIMARY}" ] && [ -d "${PLUGIN_DIR_ALT}" ]; then
        legacy_backup="${BACKUP_ROOT}/MacCmsWall_legacy_$(date +%s)_$$"
        mv "${PLUGIN_DIR_ALT}" "${legacy_backup}" >/dev/null 2>&1 || true
        warn "检测到重复目录，已迁移旧目录到: ${legacy_backup}"
    fi

    PLUGIN_DIR="${PLUGIN_DIR_PRIMARY}"
}

detect_panel() {
    if [ ! -d "${PANEL_ROOT}" ]; then
        die "未检测到面板目录 ${PANEL_ROOT}"
    fi

    local common_py="${PANEL_ROOT}/class/common.py"
    if [ -f "${common_py}" ] && grep -qi "aapanel" "${common_py}"; then
        PANEL_TYPE="aapanel"
    else
        PANEL_TYPE="bt"
    fi

    log "检测到面板类型: ${PANEL_TYPE}"
}

# 识别系统包管理器，覆盖主流发行版。
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        die "不支持的系统包管理器，请手动安装依赖"
    fi

    log "检测到包管理器: ${PKG_MANAGER}"
}

install_pkg() {
    local pkg="$1"

    if [ "${PKG_MANAGER}" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" >/dev/null
    elif [ "${PKG_MANAGER}" = "dnf" ]; then
        dnf install -y "${pkg}" >/dev/null
    else
        yum install -y "${pkg}" >/dev/null
    fi
}

ensure_cmd() {
    local cmd="$1"
    local pkg_apt="$2"
    local pkg_rpm="$3"

    if command -v "${cmd}" >/dev/null 2>&1; then
        return 0
    fi

    log "安装依赖: ${cmd}"
    if [ "${PKG_MANAGER}" = "apt" ]; then
        install_pkg "${pkg_apt}"
    else
        install_pkg "${pkg_rpm}"
    fi

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "依赖安装失败: ${cmd}"
    fi
}

install_dependencies() {
    detect_pkg_manager

    if [ "${PKG_MANAGER}" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    elif [ "${PKG_MANAGER}" = "dnf" ]; then
        dnf makecache >/dev/null
    else
        yum makecache >/dev/null
    fi

    # git/curl 用于拉取项目，sqlite3 用于数据库初始化，e2fsprogs 提供 chattr。
    ensure_cmd "git" "git" "git"
    ensure_cmd "curl" "curl" "curl"
    ensure_cmd "sqlite3" "sqlite3" "sqlite"
    ensure_cmd "python3" "python3" "python3"
    ensure_cmd "chattr" "e2fsprogs" "e2fsprogs"
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

verify_single_md5() {
    local manifest_file="$1"
    local file_path="$2"
    local short_name="$3"
    local expected actual

    [ -f "${file_path}" ] || die "缺少待校验文件: ${file_path}"

    expected="$(expected_md5_from_manifest "${manifest_file}" "${short_name}" | tr 'A-Z' 'a-z')"
    [ -n "${expected}" ] || die "校验清单缺少 ${short_name} 的 MD5"

    actual="$(md5_of_file "${file_path}" | tr 'A-Z' 'a-z')"
    [ -n "${actual}" ] || die "计算 ${short_name} 的 MD5 失败"

    if [ "${expected}" != "${actual}" ]; then
        die "检测到脚本篡改: ${short_name}，拒绝执行"
    fi
}

verify_source_integrity() {
    local manifest_file="${SOURCE_DIR}/${CHECKSUM_FILE}"

    [ -f "${manifest_file}" ] || die "源码缺少校验清单: ${CHECKSUM_FILE}"

    verify_single_md5 "${manifest_file}" "${SOURCE_DIR}/install.sh" "install.sh"
    verify_single_md5 "${manifest_file}" "${SOURCE_DIR}/update.sh" "update.sh"
    verify_single_md5 "${manifest_file}" "${SOURCE_DIR}/uninstall.sh" "uninstall.sh"
    verify_single_md5 "${manifest_file}" "${SOURCE_DIR}/onekey.sh" "onekey.sh"

    log "源码脚本 MD5 校验通过"
}

# 准备源码：优先本地目录，其次当前脚本目录，最后从 GitHub 拉取。
prepare_source() {
    local script_real plugin_real
    local has_panel_layout=0
    local has_root_layout=0
    script_real="$(cd "${SCRIPT_DIR}" && pwd -P)"

    if [ -d "${SCRIPT_DIR}/panel" ] && [ -d "${SCRIPT_DIR}/scripts" ]; then
        has_panel_layout=1
    fi

    if [ -f "${SCRIPT_DIR}/main.py" ] && [ -f "${SCRIPT_DIR}/index.html" ] && [ -f "${SCRIPT_DIR}/info.json" ] && [ -d "${SCRIPT_DIR}/scripts" ]; then
        has_root_layout=1
    fi

    if [ -n "${MACCMSWALL_LOCAL_DIR:-}" ] && [ -d "${MACCMSWALL_LOCAL_DIR}" ]; then
        SOURCE_DIR="$(cd "${MACCMSWALL_LOCAL_DIR}" && pwd)"
        log "使用本地目录安装: ${SOURCE_DIR}"
        return 0
    fi

    if [ "${has_panel_layout}" -eq 1 ] || [ "${has_root_layout}" -eq 1 ]; then
        if [ -d "${PLUGIN_DIR}" ]; then
            plugin_real="$(cd "${PLUGIN_DIR}" && pwd -P)"
        else
            plugin_real=""
        fi

        # 如果当前目录就是已安装插件目录，不能直接作为源码，否则会出现自覆盖。
        if [ -n "${plugin_real}" ] && [ "${script_real}" = "${plugin_real}" ]; then
            warn "当前目录是已安装插件目录，切换为远程拉取模式避免自覆盖"
        else
            SOURCE_DIR="${SCRIPT_DIR}"
            log "使用当前目录安装: ${SOURCE_DIR}"
            return 0
        fi
    fi

    WORK_DIR="$(mktemp -d /tmp/maccmswall-install.XXXXXX)"

    if command -v git >/dev/null 2>&1; then
        log "从 GitHub 克隆项目: ${REPO_URL}"
        git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${WORK_DIR}/src" >/dev/null 2>&1 || die "克隆项目失败"
        SOURCE_DIR="${WORK_DIR}/src"
        return 0
    fi

    # 兜底方式：不依赖 git，使用 tar.gz 拉取。
    local tar_url="${REPO_URL%.git}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    log "通过压缩包下载项目: ${tar_url}"
    curl -fsSL "${tar_url}" -o "${WORK_DIR}/src.tar.gz" || die "下载项目压缩包失败"
    mkdir -p "${WORK_DIR}/unpack"
    tar -xzf "${WORK_DIR}/src.tar.gz" -C "${WORK_DIR}/unpack" || die "解压项目失败"

    local first_dir
    first_dir="$(find "${WORK_DIR}/unpack" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -n "${first_dir}" ] || die "未找到解压后的项目目录"

    mkdir -p "${WORK_DIR}/src"
    cp -a "${first_dir}/." "${WORK_DIR}/src/" || die "拷贝项目文件失败"
    SOURCE_DIR="${WORK_DIR}/src"
}

validate_source() {
    local panel_layout=0
    local root_layout=0

    if [ -f "${SOURCE_DIR}/panel/main.py" ] && [ -f "${SOURCE_DIR}/panel/index.html" ] && [ -f "${SOURCE_DIR}/panel/info.json" ]; then
        panel_layout=1
    fi

    if [ -f "${SOURCE_DIR}/main.py" ] && [ -f "${SOURCE_DIR}/index.html" ] && [ -f "${SOURCE_DIR}/info.json" ]; then
        root_layout=1
    fi

    if [ "${panel_layout}" -ne 1 ] && [ "${root_layout}" -ne 1 ]; then
        die "源码结构不完整，需满足 panel 结构或插件根目录结构"
    fi

    [ -d "${SOURCE_DIR}/scripts" ] || die "源码缺少 scripts 目录"
}

# 复制源码到面板插件目录。
copy_source_to_plugin() {
    if [ -f "${SOURCE_DIR}/panel/main.py" ] && [ -f "${SOURCE_DIR}/panel/index.html" ] && [ -f "${SOURCE_DIR}/panel/info.json" ]; then
        # 开发仓库使用 panel 子目录，部署时需要展开到插件根目录以兼容 BT/aaPanel。
        cp -a "${SOURCE_DIR}/panel/." "${PLUGIN_DIR}/" || die "复制 panel 目录失败"
        cp -a "${SOURCE_DIR}/scripts" "${PLUGIN_DIR}/scripts" || die "复制 scripts 目录失败"

        if [ -d "${SOURCE_DIR}/database" ]; then
            cp -a "${SOURCE_DIR}/database" "${PLUGIN_DIR}/database" || die "复制 database 目录失败"
        fi

        if [ -d "${SOURCE_DIR}/logs" ]; then
            cp -a "${SOURCE_DIR}/logs" "${PLUGIN_DIR}/logs" || die "复制 logs 目录失败"
        fi

        if [ -f "${SOURCE_DIR}/install.sh" ]; then
            cp -a "${SOURCE_DIR}/install.sh" "${PLUGIN_DIR}/install.sh" || die "复制 install.sh 失败"
        fi

        if [ -f "${SOURCE_DIR}/uninstall.sh" ]; then
            cp -a "${SOURCE_DIR}/uninstall.sh" "${PLUGIN_DIR}/uninstall.sh" || die "复制 uninstall.sh 失败"
        fi

        if [ -f "${SOURCE_DIR}/update.sh" ]; then
            cp -a "${SOURCE_DIR}/update.sh" "${PLUGIN_DIR}/update.sh" || die "复制 update.sh 失败"
        fi

        if [ -f "${SOURCE_DIR}/onekey.sh" ]; then
            cp -a "${SOURCE_DIR}/onekey.sh" "${PLUGIN_DIR}/onekey.sh" || die "复制 onekey.sh 失败"
        fi

        if [ -f "${SOURCE_DIR}/${CHECKSUM_FILE}" ]; then
            cp -a "${SOURCE_DIR}/${CHECKSUM_FILE}" "${PLUGIN_DIR}/${CHECKSUM_FILE}" || die "复制 ${CHECKSUM_FILE} 失败"
        fi

        if [ -f "${SOURCE_DIR}/README.md" ]; then
            cp -a "${SOURCE_DIR}/README.md" "${PLUGIN_DIR}/README.md" || die "复制 README.md 失败"
        fi
        return 0
    fi

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude ".git" --exclude ".github" "${SOURCE_DIR}/" "${PLUGIN_DIR}/" || die "部署文件失败"
    else
        cp -a "${SOURCE_DIR}/." "${PLUGIN_DIR}/" || die "部署文件失败"
    fi
}

# 升级时恢复旧版本中的持久化数据，避免更新导致数据丢失。
restore_persistent_data() {
    [ -n "${BACKUP_DIR}" ] || return 0

    mkdir -p "${PLUGIN_DIR}/database" "${PLUGIN_DIR}/logs" "${PLUGIN_DIR}/data" "${PLUGIN_DIR}/templates"

    if [ -f "${BACKUP_DIR}/database/maccmswall.db" ]; then
        cp -a "${BACKUP_DIR}/database/maccmswall.db" "${PLUGIN_DIR}/database/maccmswall.db" || die "恢复数据库失败"
        log "已恢复历史数据库"
    fi

    if [ -f "${BACKUP_DIR}/logs/maccmswall.log" ]; then
        cp -a "${BACKUP_DIR}/logs/maccmswall.log" "${PLUGIN_DIR}/logs/maccmswall.log" || die "恢复日志失败"
        log "已恢复历史日志"
    fi

    # 兼容旧版数据目录位置，尽量保留插件运行产生的数据。
    if [ -d "${BACKUP_DIR}/data" ]; then
        cp -a "${BACKUP_DIR}/data/." "${PLUGIN_DIR}/data/" >/dev/null 2>&1 || true
    elif [ -d "${BACKUP_DIR}/panel/data" ]; then
        cp -a "${BACKUP_DIR}/panel/data/." "${PLUGIN_DIR}/data/" >/dev/null 2>&1 || true
    fi
}

deploy_plugin() {
    local source_real target_real

    mkdir -p "${PANEL_ROOT}/plugin"

    source_real="$(cd "${SOURCE_DIR}" && pwd -P)"
    if [ -d "${PLUGIN_DIR}" ]; then
        target_real="$(cd "${PLUGIN_DIR}" && pwd -P)"
    else
        target_real=""
    fi

    if [ -n "${target_real}" ] && [ "${source_real}" = "${target_real}" ]; then
        die "源码目录与目标目录相同，无法部署，请改用 MACCMSWALL_LOCAL_DIR 或 GitHub 安装"
    fi

    if [ -d "${PLUGIN_DIR}" ]; then
        local backup_dir=""
        ensure_backup_root
        backup_dir="${BACKUP_ROOT}/$(basename "${PLUGIN_DIR}")_backup_$(date +%s)_$$"
        warn "检测到旧版本，先备份到 ${backup_dir}"
        mv "${PLUGIN_DIR}" "${backup_dir}" || die "备份旧版本失败"
        BACKUP_DIR="${backup_dir}"
    fi

    mkdir -p "${PLUGIN_DIR}"

    copy_source_to_plugin

    chmod +x "${PLUGIN_DIR}/install.sh" "${PLUGIN_DIR}/uninstall.sh" "${PLUGIN_DIR}/update.sh" "${PLUGIN_DIR}/onekey.sh" >/dev/null 2>&1 || true
    chmod +x "${PLUGIN_DIR}/scripts"/*.sh >/dev/null 2>&1 || true
}

# 创建大小写目录别名，提升 BT/aaPanel 扫描兼容性。
ensure_plugin_alias() {
    if [ "${MACCMSWALL_CREATE_ALIAS:-0}" != "1" ]; then
        return 0
    fi

    local alias_dir=""

    if [ "${PLUGIN_DIR}" = "${PLUGIN_DIR_PRIMARY}" ]; then
        alias_dir="${PLUGIN_DIR_ALT}"
    else
        alias_dir="${PLUGIN_DIR_PRIMARY}"
    fi

    if [ -e "${alias_dir}" ]; then
        return 0
    fi

    ln -s "${PLUGIN_DIR}" "${alias_dir}" >/dev/null 2>&1 && log "已创建兼容别名: ${alias_dir}" || true
}

# 若历史版本缺少 name_main.py，则自动补齐兼容入口。
ensure_bt_entry_wrapper() {
    local lower_entry="${PLUGIN_DIR}/maccmswall_main.py"

    if [ -f "${lower_entry}" ]; then
        return 0
    fi

    if [ ! -f "${PLUGIN_DIR}/main.py" ]; then
        return 0
    fi

    cat > "${lower_entry}" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from main import main as _Main


class maccmswall_main(_Main):
    pass


class MacCmsWall_main(maccmswall_main):
    pass
PY
}

# 在 Linux 侧补齐历史入口文件名，兼容 name=MacCmsWall 的旧路由。
ensure_legacy_python_entry() {
    local lower_entry="${PLUGIN_DIR}/maccmswall_main.py"
    local legacy_entry="${PLUGIN_DIR}/MacCmsWall_main.py"

    if [ -f "${lower_entry}" ] && [ ! -f "${legacy_entry}" ]; then
        cp -a "${lower_entry}" "${legacy_entry}" >/dev/null 2>&1 || true
    fi
}

run_panel_local_install() {
    require_root
    detect_panel

    if is_plugin_runtime_dir; then
        PLUGIN_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
    else
        select_plugin_dir
    fi

    ensure_backup_root
    normalize_plugin_layout

    is_plugin_root_layout "${PLUGIN_DIR}" || die "插件目录结构不完整: ${PLUGIN_DIR}"

    chmod +x "${PLUGIN_DIR}/install.sh" "${PLUGIN_DIR}/uninstall.sh" "${PLUGIN_DIR}/update.sh" "${PLUGIN_DIR}/onekey.sh" >/dev/null 2>&1 || true
    chmod +x "${PLUGIN_DIR}/scripts"/*.sh >/dev/null 2>&1 || true

    ensure_bt_entry_wrapper
    ensure_plugin_alias
    ensure_legacy_python_entry

    if command -v sqlite3 >/dev/null 2>&1; then
        init_database
    else
        warn "未检测到 sqlite3，跳过数据库初始化"
    fi

    refresh_plugin_cache

    log "插件本地安装收尾完成: ${PLUGIN_DIR}"
    if restart_panel; then
        log "面板重启成功"
    else
        warn "未能自动重启面板，请手动执行: bt restart 或 /etc/init.d/aapanel restart"
    fi
}

run_panel_local_uninstall() {
    require_root

    if [ -x "${SCRIPT_DIR}/uninstall.sh" ]; then
        bash "${SCRIPT_DIR}/uninstall.sh"
        return 0
    fi

    die "缺少卸载脚本: ${SCRIPT_DIR}/uninstall.sh"
}

# 强制刷新插件缓存，避免文件已部署但列表页未及时刷新。
refresh_plugin_cache() {
    rm -f "${PANEL_ROOT}/data/plugin.json" >/dev/null 2>&1 || true
    rm -f "${PANEL_ROOT}/data/plugin_list.json" >/dev/null 2>&1 || true
    touch "${PANEL_ROOT}/data/reload.pl" >/dev/null 2>&1 || true
}

init_database() {
    local db_file="${PLUGIN_DIR}/database/maccmswall.db"
    local init_sql="${PLUGIN_DIR}/database/init.sql"

    mkdir -p "${PLUGIN_DIR}/database" "${PLUGIN_DIR}/logs" "${PLUGIN_DIR}/data" "${PLUGIN_DIR}/templates"
    touch "${PLUGIN_DIR}/logs/maccmswall.log"

    if [ -f "${init_sql}" ]; then
        sqlite3 "${db_file}" < "${init_sql}" || die "执行 init.sql 失败"
        return 0
    fi

    sqlite3 "${db_file}" <<'SQL'
CREATE TABLE IF NOT EXISTS sites(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    site_name TEXT NOT NULL,
    site_path TEXT NOT NULL UNIQUE,
    mode TEXT NOT NULL DEFAULT 'strict',
    status INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_locked_at INTEGER NOT NULL DEFAULT 0,
    last_unlocked_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS files(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    site_id INTEGER NOT NULL,
    file_path TEXT NOT NULL,
    locked INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY(site_id) REFERENCES sites(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS logs(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    level TEXT NOT NULL,
    action TEXT NOT NULL,
    site_id INTEGER DEFAULT 0,
    message TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_files_site_id ON files(site_id);
CREATE INDEX IF NOT EXISTS idx_files_locked ON files(locked);
CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at);
SQL

    [ "$?" -eq 0 ] || die "初始化数据库失败"
}

restart_panel() {
    # 尽量自动重启，失败时给出手动提示。
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

    # bt 命令放最后，避免在面板内置终端里中断当前会话。
    if command -v bt >/dev/null 2>&1; then
        bt restart >/dev/null 2>&1 && return 0
    fi

    return 1
}

main() {
    trap cleanup EXIT

    case "${1:-}" in
        install)
            run_panel_local_install
            return 0
            ;;
        uninstall)
            run_panel_local_uninstall
            return 0
            ;;
        "")
            if is_plugin_runtime_dir && is_plugin_root_layout "${SCRIPT_DIR}"; then
                log "检测到面板插件目录环境，执行本地安装收尾流程"
                run_panel_local_install
                return 0
            fi
            ;;
        *)
            warn "未知参数: ${1}，按标准安装流程继续"
            ;;
    esac

    require_root
    select_plugin_dir
    detect_panel
    normalize_plugin_layout
    install_dependencies
    prepare_source
    validate_source
    verify_source_integrity
    deploy_plugin
    ensure_plugin_alias
    ensure_legacy_python_entry
    restore_persistent_data
    init_database
    refresh_plugin_cache

    log "插件已部署: ${PLUGIN_DIR}"
    log "正在尝试刷新/重启面板服务..."

    if restart_panel; then
        log "面板重启成功"
    else
        warn "未能自动重启面板，请手动执行: bt restart 或 /etc/init.d/aapanel restart"
    fi

    log "安装完成"
    log "插件目录: ${PLUGIN_DIR}"
    log "请在面板左侧菜单进入 ${PLUGIN_TITLE}"
}

main "$@"
