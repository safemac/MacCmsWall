#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MacCmsWall 插件主入口。
职责：
1. 提供 Web API 给前端调用。
2. 管理 SQLite 数据库。
3. 调用 shell 脚本执行扫描、加锁、解锁。
4. 记录操作日志并返回状态。
"""

import json
import os
import sqlite3
import subprocess
import threading
import time
import traceback
from typing import Any, Dict, Optional


BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DB_PATH = os.path.join(BASE_DIR, "database", "maccmswall.db")
LOG_FILE = os.path.join(BASE_DIR, "logs", "maccmswall.log")
SCRIPTS_DIR = os.path.join(BASE_DIR, "scripts")


class main:  # noqa: N801  # 宝塔插件约定入口类名为 main
    """MacCmsWall API 实现类。"""

    _db_lock = threading.Lock()

    def __init__(self):
        # 初始化运行环境和数据库。
        self._ensure_environment()
        self._init_db()

    # =========================
    # 对外 API：基础查询
    # =========================
    def health(self, get=None):
        """健康检查接口。"""
        return self._ok({
            "name": "MacCmsWall",
            "version": "1.0.0",
            "time": int(time.time()),
            "db_path": DB_PATH,
            "log_file": LOG_FILE,
        })

    def get_modes(self, get=None):
        """返回当前支持的防护模式。"""
        return self._ok({
            "modes": [
                {"value": "strict", "label": "严格全锁模式"},
                {"value": "maccms", "label": "MACCMS 兼容模式"},
            ]
        })

    def get_dashboard(self, get=None):
        """聚合仪表盘数据。"""
        try:
            with self._get_conn() as conn:
                total_sites = self._fetch_one_value(conn, "SELECT COUNT(1) FROM sites;")
                protected_sites = self._fetch_one_value(conn, "SELECT COUNT(1) FROM sites WHERE status=1;")
                total_files = self._fetch_one_value(conn, "SELECT COUNT(1) FROM files;")
                locked_files = self._fetch_one_value(conn, "SELECT COUNT(1) FROM files WHERE locked=1;")

                row = conn.execute(
                    "SELECT created_at, action, message FROM logs ORDER BY id DESC LIMIT 1;"
                ).fetchone()
                last_action = {
                    "created_at": row["created_at"] if row else 0,
                    "action": row["action"] if row else "-",
                    "message": row["message"] if row else "暂无操作记录",
                }

                modes = conn.execute(
                    "SELECT mode, COUNT(1) AS cnt FROM sites GROUP BY mode;"
                ).fetchall()
                mode_stats = {item["mode"]: item["cnt"] for item in modes}

            return self._ok({
                "total_sites": int(total_sites or 0),
                "protected_sites": int(protected_sites or 0),
                "total_files": int(total_files or 0),
                "locked_files": int(locked_files or 0),
                "last_action": last_action,
                "mode_stats": mode_stats,
            })
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("dashboard", err)
            return self._fail(f"获取仪表盘失败: {err}")

    def list_sites(self, get=None):
        """返回站点列表及统计信息。"""
        try:
            with self._get_conn() as conn:
                rows = conn.execute(
                    """
                    SELECT
                        s.id,
                        s.site_name,
                        s.site_path,
                        s.mode,
                        s.status,
                        s.created_at,
                        s.updated_at,
                        s.last_locked_at,
                        s.last_unlocked_at,
                        COUNT(f.id) AS file_count,
                        COALESCE(SUM(f.locked), 0) AS locked_count
                    FROM sites s
                    LEFT JOIN files f ON s.id=f.site_id
                    GROUP BY s.id
                    ORDER BY s.id DESC;
                    """
                ).fetchall()

            sites = []
            for row in rows:
                sites.append({
                    "id": row["id"],
                    "site_name": row["site_name"],
                    "site_path": row["site_path"],
                    "mode": row["mode"],
                    "status": row["status"],
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                    "last_locked_at": row["last_locked_at"],
                    "last_unlocked_at": row["last_unlocked_at"],
                    "file_count": row["file_count"],
                    "locked_count": row["locked_count"],
                })

            return self._ok({"sites": sites})
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("list_sites", err)
            return self._fail(f"获取站点列表失败: {err}")

    # =========================
    # 对外 API：站点管理
    # =========================
    def add_site(self, get=None):
        """新增受保护站点。"""
        try:
            site_name = str(self._param(get, "site_name", "")).strip()
            site_path = str(self._param(get, "site_path", "")).strip()
            mode = str(self._param(get, "mode", "strict")).strip()

            if not site_name:
                return self._fail("站点名称不能为空")
            if not site_path:
                return self._fail("站点路径不能为空")
            if mode not in ("strict", "maccms"):
                return self._fail("模式仅支持 strict 或 maccms")

            site_path = os.path.realpath(site_path)
            if not os.path.isdir(site_path):
                return self._fail("站点路径不存在或不是目录")

            now = int(time.time())
            with self._db_lock, self._get_conn() as conn:
                exists = conn.execute(
                    "SELECT id FROM sites WHERE site_path=?;",
                    (site_path,),
                ).fetchone()
                if exists:
                    return self._fail("该站点路径已存在，请勿重复添加")

                cur = conn.execute(
                    """
                    INSERT INTO sites(site_name,site_path,mode,status,created_at,updated_at,last_locked_at,last_unlocked_at)
                    VALUES(?,?,?,?,?,?,?,?);
                    """,
                    (site_name, site_path, mode, 0, now, now, 0, 0),
                )
                site_id = int(cur.lastrowid)

            self._write_log("add_site", "INFO", f"新增站点: {site_name}", site_id)
            return self._ok({"site_id": site_id}, "新增站点成功")
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("add_site", err)
            return self._fail(f"新增站点失败: {err}")

    def update_mode(self, get=None):
        """更新站点防护模式。"""
        try:
            site_id = self._to_int(self._param(get, "site_id", 0))
            mode = str(self._param(get, "mode", "strict")).strip()

            if site_id <= 0:
                return self._fail("site_id 无效")
            if mode not in ("strict", "maccms"):
                return self._fail("模式仅支持 strict 或 maccms")

            now = int(time.time())
            with self._db_lock, self._get_conn() as conn:
                row = conn.execute("SELECT id,status FROM sites WHERE id=?;", (site_id,)).fetchone()
                if not row:
                    return self._fail("站点不存在")

                conn.execute(
                    "UPDATE sites SET mode=?,updated_at=? WHERE id=?;",
                    (mode, now, site_id),
                )

            self._write_log("update_mode", "INFO", f"更新模式为 {mode}", site_id)
            return self._ok({}, "更新模式成功")
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("update_mode", err)
            return self._fail(f"更新模式失败: {err}")

    def remove_site(self, get=None):
        """删除站点。删除前若在防护中，会先执行解锁。"""
        try:
            site_id = self._to_int(self._param(get, "site_id", 0))
            if site_id <= 0:
                return self._fail("site_id 无效")

            site = self._get_site(site_id)
            if not site:
                return self._fail("站点不存在")

            if int(site["status"]) == 1:
                unlock_ret = self._run_script("unlock.sh", [str(site_id), DB_PATH, LOG_FILE])
                if unlock_ret["returncode"] != 0:
                    return self._fail("删除前解锁失败，请先关闭防护", data=unlock_ret)

            with self._db_lock, self._get_conn() as conn:
                conn.execute("DELETE FROM files WHERE site_id=?;", (site_id,))
                conn.execute("DELETE FROM sites WHERE id=?;", (site_id,))

            self._write_log("remove_site", "INFO", f"删除站点: {site['site_name']}", site_id)
            return self._ok({}, "删除站点成功")
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("remove_site", err)
            return self._fail(f"删除站点失败: {err}")

    # =========================
    # 对外 API：防护控制
    # =========================
    def enable_protection(self, get=None):
        """开启防护：扫描 -> 写库 -> 加锁。"""
        try:
            site_id = self._to_int(self._param(get, "site_id", 0))
            if site_id <= 0:
                return self._fail("site_id 无效")

            site = self._get_site(site_id)
            if not site:
                return self._fail("站点不存在")

            site_path = site["site_path"]
            mode = site["mode"]
            now = int(time.time())

            if not os.path.isdir(site_path):
                return self._fail("站点目录不存在")

            scan_ret = self._run_script(
                "scan.sh",
                [str(site_id), site_path, mode, DB_PATH, LOG_FILE],
            )
            if scan_ret["returncode"] != 0:
                self._write_log("enable_protection", "ERROR", "扫描失败", site_id)
                return self._fail("开启防护失败：扫描失败", data=scan_ret)

            lock_ret = self._run_script(
                "lock.sh",
                [str(site_id), site_path, mode, DB_PATH, LOG_FILE],
            )
            if lock_ret["returncode"] != 0:
                # 为避免部分文件已锁造成维护困难，失败时尝试回滚解锁。
                self._run_script("unlock.sh", [str(site_id), DB_PATH, LOG_FILE])
                self._write_log("enable_protection", "ERROR", "加锁失败，已尝试回滚", site_id)
                return self._fail("开启防护失败：加锁失败", data=lock_ret)

            with self._db_lock, self._get_conn() as conn:
                conn.execute(
                    "UPDATE sites SET status=1,updated_at=?,last_locked_at=? WHERE id=?;",
                    (now, now, site_id),
                )

            self._write_log("enable_protection", "INFO", "开启防护成功", site_id)
            return self._ok({"scan": scan_ret["metrics"], "lock": lock_ret["metrics"]}, "开启防护成功")
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("enable_protection", err)
            return self._fail(f"开启防护失败: {err}")

    def disable_protection(self, get=None):
        """关闭防护：读取数据库 -> 批量解锁。"""
        try:
            site_id = self._to_int(self._param(get, "site_id", 0))
            if site_id <= 0:
                return self._fail("site_id 无效")

            site = self._get_site(site_id)
            if not site:
                return self._fail("站点不存在")

            unlock_ret = self._run_script("unlock.sh", [str(site_id), DB_PATH, LOG_FILE])
            if unlock_ret["returncode"] != 0:
                self._write_log("disable_protection", "ERROR", "解锁失败", site_id)
                return self._fail("关闭防护失败：解锁失败", data=unlock_ret)

            now = int(time.time())
            with self._db_lock, self._get_conn() as conn:
                conn.execute(
                    "UPDATE sites SET status=0,updated_at=?,last_unlocked_at=? WHERE id=?;",
                    (now, now, site_id),
                )

            self._write_log("disable_protection", "INFO", "关闭防护成功", site_id)
            return self._ok({"unlock": unlock_ret["metrics"]}, "关闭防护成功")
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("disable_protection", err)
            return self._fail(f"关闭防护失败: {err}")

    def rescan_site(self, get=None):
        """重新扫描：更新数据库文件索引，不改变站点当前启停状态。"""
        try:
            site_id = self._to_int(self._param(get, "site_id", 0))
            if site_id <= 0:
                return self._fail("site_id 无效")

            site = self._get_site(site_id)
            if not site:
                return self._fail("站点不存在")

            site_path = site["site_path"]
            mode = site["mode"]

            if not os.path.isdir(site_path):
                return self._fail("站点目录不存在")

            was_protected = int(site["status"]) == 1
            unlock_ret = None

            # 防护状态下重扫前先解锁，避免扫描后再加锁出现状态不一致。
            if was_protected:
                unlock_ret = self._run_script("unlock.sh", [str(site_id), DB_PATH, LOG_FILE])
                if unlock_ret["returncode"] != 0:
                    return self._fail("重扫前解锁失败", data=unlock_ret)

            scan_ret = self._run_script(
                "scan.sh",
                [str(site_id), site_path, mode, DB_PATH, LOG_FILE],
            )
            if scan_ret["returncode"] != 0:
                return self._fail("重扫失败", data=scan_ret)

            relock_ret = None
            if was_protected:
                relock_ret = self._run_script(
                    "lock.sh",
                    [str(site_id), site_path, mode, DB_PATH, LOG_FILE],
                )
                if relock_ret["returncode"] != 0:
                    return self._fail("重扫后重新加锁失败", data=relock_ret)

            now = int(time.time())
            with self._db_lock, self._get_conn() as conn:
                conn.execute("UPDATE sites SET updated_at=? WHERE id=?;", (now, site_id))

            self._write_log("rescan_site", "INFO", "重新扫描完成", site_id)
            return self._ok(
                {
                    "unlock": unlock_ret["metrics"] if unlock_ret else {},
                    "scan": scan_ret["metrics"],
                    "relock": relock_ret["metrics"] if relock_ret else {},
                },
                "重新扫描成功",
            )
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("rescan_site", err)
            return self._fail(f"重新扫描失败: {err}")

    def relock_site(self, get=None):
        """重新加锁：按当前数据库索引再次执行 chattr +i。"""
        try:
            site_id = self._to_int(self._param(get, "site_id", 0))
            if site_id <= 0:
                return self._fail("site_id 无效")

            site = self._get_site(site_id)
            if not site:
                return self._fail("站点不存在")

            site_path = site["site_path"]
            mode = site["mode"]

            if not os.path.isdir(site_path):
                return self._fail("站点目录不存在")

            lock_ret = self._run_script(
                "lock.sh",
                [str(site_id), site_path, mode, DB_PATH, LOG_FILE],
            )
            if lock_ret["returncode"] != 0:
                return self._fail("重新加锁失败", data=lock_ret)

            now = int(time.time())
            with self._db_lock, self._get_conn() as conn:
                conn.execute(
                    "UPDATE sites SET status=1,updated_at=?,last_locked_at=? WHERE id=?;",
                    (now, now, site_id),
                )

            self._write_log("relock_site", "INFO", "重新加锁成功", site_id)
            return self._ok({"lock": lock_ret["metrics"]}, "重新加锁成功")
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("relock_site", err)
            return self._fail(f"重新加锁失败: {err}")

    # =========================
    # 对外 API：日志
    # =========================
    def get_logs(self, get=None):
        """读取日志记录。"""
        try:
            limit = self._to_int(self._param(get, "limit", 200))
            site_id = self._to_int(self._param(get, "site_id", 0))
            if limit <= 0:
                limit = 200
            if limit > 2000:
                limit = 2000

            with self._get_conn() as conn:
                if site_id > 0:
                    rows = conn.execute(
                        """
                        SELECT id,level,action,site_id,message,created_at
                        FROM logs
                        WHERE site_id=?
                        ORDER BY id DESC
                        LIMIT ?;
                        """,
                        (site_id, limit),
                    ).fetchall()
                else:
                    rows = conn.execute(
                        """
                        SELECT id,level,action,site_id,message,created_at
                        FROM logs
                        ORDER BY id DESC
                        LIMIT ?;
                        """,
                        (limit,),
                    ).fetchall()

            logs = []
            for row in rows:
                logs.append(
                    {
                        "id": row["id"],
                        "level": row["level"],
                        "action": row["action"],
                        "site_id": row["site_id"],
                        "message": row["message"],
                        "created_at": row["created_at"],
                    }
                )

            return self._ok({"logs": logs})
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("get_logs", err)
            return self._fail(f"读取日志失败: {err}")

    def clear_logs(self, get=None):
        """清空数据库日志。"""
        try:
            with self._db_lock, self._get_conn() as conn:
                conn.execute("DELETE FROM logs;")
            self._append_file_log("INFO", "日志已清空")
            return self._ok({}, "日志已清空")
        except Exception as err:  # pylint: disable=broad-except
            self._write_runtime_error("clear_logs", err)
            return self._fail(f"清空日志失败: {err}")

    # =========================
    # 内部方法：数据库与脚本
    # =========================
    def _ensure_environment(self):
        """确保目录和日志文件存在。"""
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        os.makedirs(SCRIPTS_DIR, exist_ok=True)

        if not os.path.exists(LOG_FILE):
            with open(LOG_FILE, "a", encoding="utf-8"):
                pass

    def _init_db(self):
        """初始化数据库结构。"""
        with self._db_lock, self._get_conn() as conn:
            conn.executescript(
                """
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
                """
            )

    def _get_conn(self):
        """创建 SQLite 连接并开启外键。"""
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON;")
        return conn

    def _run_script(self, script_name: str, args: list, timeout: int = 1800) -> Dict[str, Any]:
        """执行 shell 脚本并返回结构化结果。"""
        script_path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(script_path):
            return {
                "returncode": 127,
                "stdout": "",
                "stderr": f"脚本不存在: {script_path}",
                "metrics": {},
            }

        cmd = ["bash", script_path] + [str(item) for item in args]
        try:
            proc = subprocess.run(  # noqa: S603
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
                check=False,
            )
        except Exception as err:  # pylint: disable=broad-except
            return {
                "returncode": 500,
                "stdout": "",
                "stderr": str(err),
                "metrics": {},
            }

        metrics = self._parse_metrics(proc.stdout)
        if proc.returncode != 0:
            self._append_file_log(
                "ERROR",
                f"脚本执行失败 script={script_name} code={proc.returncode} stderr={proc.stderr.strip()}",
            )

        return {
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "metrics": metrics,
        }

    def _parse_metrics(self, text: str) -> Dict[str, int]:
        """解析脚本输出中的 KEY=VALUE 统计项。"""
        result: Dict[str, int] = {}
        for line in text.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if not key.isupper():
                continue
            try:
                result[key] = int(value)
            except ValueError:
                continue
        return result

    def _get_site(self, site_id: int) -> Optional[sqlite3.Row]:
        """按站点 ID 获取站点信息。"""
        with self._get_conn() as conn:
            return conn.execute(
                "SELECT * FROM sites WHERE id=?;",
                (site_id,),
            ).fetchone()

    # =========================
    # 内部方法：日志与返回
    # =========================
    def _write_log(self, action: str, level: str, message: str, site_id: int = 0):
        """写入数据库日志并同步写入文本日志。"""
        now = int(time.time())
        with self._db_lock, self._get_conn() as conn:
            conn.execute(
                "INSERT INTO logs(level,action,site_id,message,created_at) VALUES(?,?,?,?,?);",
                (level, action, int(site_id), message, now),
            )
        self._append_file_log(level, f"action={action} site_id={site_id} message={message}")

    def _append_file_log(self, level: str, message: str):
        """写入文本日志文件。"""
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
        line = f"{ts} [{level}] {message}\n"
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)

    def _write_runtime_error(self, action: str, err: Exception):
        """写入运行时异常日志，便于排障。"""
        message = f"{err}\n{traceback.format_exc()}"
        self._append_file_log("ERROR", f"action={action} exception={message}")

    def _fetch_one_value(self, conn: sqlite3.Connection, sql: str) -> int:
        """执行单值查询。"""
        row = conn.execute(sql).fetchone()
        if row is None:
            return 0
        # sqlite3.Row 支持索引访问，单列查询使用 0 即可。
        return int(row[0] or 0)

    def _param(self, get: Any, key: str, default: Any = None) -> Any:
        """兼容 dict / 对象 两种参数读取方式。"""
        if get is None:
            return default
        if isinstance(get, dict):
            return get.get(key, default)
        return getattr(get, key, default)

    def _to_int(self, value: Any, default: int = 0) -> int:
        """安全地转换整数。"""
        try:
            return int(value)
        except Exception:  # pylint: disable=broad-except
            return default

    def _ok(self, data: Optional[Dict[str, Any]] = None, msg: str = "success"):
        """统一成功返回结构。"""
        return {
            "status": True,
            "msg": msg,
            "data": data or {},
        }

    def _fail(self, msg: str, code: int = 1, data: Optional[Dict[str, Any]] = None):
        """统一失败返回结构。"""
        return {
            "status": False,
            "code": code,
            "msg": msg,
            "data": data or {},
        }


if __name__ == "__main__":
    # 本地调试入口：仅用于快速验证数据库和健康接口是否可用。
    app = main()
    print(json.dumps(app.health(), ensure_ascii=False, indent=2))
