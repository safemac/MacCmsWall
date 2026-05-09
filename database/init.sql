-- MacCmsWall 数据库初始化脚本
-- 说明：安装脚本与后端都会使用相同结构，保证可重复部署。

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
