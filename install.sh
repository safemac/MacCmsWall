#!/usr/bin/env bash
# MacCmsWall 自动安装脚本
# 兼容：CentOS / Debian / Ubuntu

set -u
set -o pipefail

PLUGIN_NAME="MacCmsWall"
PANEL_ROOT="/www/server/panel"
PLUGIN_DIR="${PANEL_ROOT}/plugin/${PLUGIN_NAME}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 可通过环境变量覆盖仓库地址和分支，便于私有仓库部署。
REPO_URL="${MACCMSWALL_REPO:-https://github.com/safemac/MacCmsWall.git}"
REPO_BRANCH="${MACCMSWALL_BRANCH:-main}"

PANEL_TYPE="bt"
PKG_MANAGER=""
WORK_DIR=""
SOURCE_DIR=""
BACKUP_DIR=""

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
        local backup_dir="${PLUGIN_DIR}_backup_$(date +%s)"
        warn "检测到旧版本，先备份到 ${backup_dir}"
        mv "${PLUGIN_DIR}" "${backup_dir}" || die "备份旧版本失败"
        BACKUP_DIR="${backup_dir}"
    fi

    mkdir -p "${PLUGIN_DIR}"

    copy_source_to_plugin

    chmod +x "${PLUGIN_DIR}/install.sh" "${PLUGIN_DIR}/uninstall.sh" "${PLUGIN_DIR}/update.sh" >/dev/null 2>&1 || true
    chmod +x "${PLUGIN_DIR}/scripts"/*.sh >/dev/null 2>&1 || true
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
    if command -v bt >/dev/null 2>&1; then
        bt restart >/dev/null 2>&1 && return 0
    fi

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

    return 1
}

main() {
    trap cleanup EXIT

    require_root
    detect_panel
    install_dependencies
    prepare_source
    validate_source
    deploy_plugin
    restore_persistent_data
    init_database

    if restart_panel; then
        log "面板重启成功"
    else
        warn "未能自动重启面板，请手动执行: bt restart 或 /etc/init.d/aapanel restart"
    fi

    log "安装完成"
    log "插件目录: ${PLUGIN_DIR}"
    log "请在面板左侧菜单进入 ${PLUGIN_NAME}"
}

main "$@"
