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
REPO_URL="${MACCMSWALL_REPO:-https://github.com/xxx/MacCmsWall.git}"
REPO_BRANCH="${MACCMSWALL_BRANCH:-main}"

PANEL_TYPE="bt"
PKG_MANAGER=""
WORK_DIR=""
SOURCE_DIR=""

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
    if [ -n "${MACCMSWALL_LOCAL_DIR:-}" ] && [ -d "${MACCMSWALL_LOCAL_DIR}" ]; then
        SOURCE_DIR="$(cd "${MACCMSWALL_LOCAL_DIR}" && pwd)"
        log "使用本地目录安装: ${SOURCE_DIR}"
        return 0
    fi

    if [ -d "${SCRIPT_DIR}/panel" ] && [ -d "${SCRIPT_DIR}/scripts" ]; then
        SOURCE_DIR="${SCRIPT_DIR}"
        log "使用当前目录安装: ${SOURCE_DIR}"
        return 0
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
    [ -f "${SOURCE_DIR}/panel/main.py" ] || die "源码缺少 panel/main.py"
    [ -f "${SOURCE_DIR}/panel/index.html" ] || die "源码缺少 panel/index.html"
    [ -d "${SOURCE_DIR}/scripts" ] || die "源码缺少 scripts 目录"
}

deploy_plugin() {
    mkdir -p "${PANEL_ROOT}/plugin"

    if [ -d "${PLUGIN_DIR}" ]; then
        local backup_dir="${PLUGIN_DIR}_backup_$(date +%s)"
        warn "检测到旧版本，先备份到 ${backup_dir}"
        mv "${PLUGIN_DIR}" "${backup_dir}" || die "备份旧版本失败"
    fi

    mkdir -p "${PLUGIN_DIR}"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude ".git" --exclude ".github" "${SOURCE_DIR}/" "${PLUGIN_DIR}/" || die "部署文件失败"
    else
        cp -a "${SOURCE_DIR}/." "${PLUGIN_DIR}/" || die "部署文件失败"
    fi

    chmod +x "${PLUGIN_DIR}/install.sh" "${PLUGIN_DIR}/uninstall.sh" >/dev/null 2>&1 || true
    chmod +x "${PLUGIN_DIR}/scripts"/*.sh >/dev/null 2>&1 || true
}

init_database() {
    local db_file="${PLUGIN_DIR}/database/maccmswall.db"

    mkdir -p "${PLUGIN_DIR}/database" "${PLUGIN_DIR}/logs" "${PLUGIN_DIR}/panel/data" "${PLUGIN_DIR}/panel/templates"
    touch "${PLUGIN_DIR}/logs/maccmswall.log"

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
