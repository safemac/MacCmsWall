# MacCmsWall

MacCmsWall 是一个基于 Linux `chattr +i` 的网站防篡改插件，面向 BT / aaPanel 第三方插件部署场景。

## 核心目标

当前版本只解决一件事：网站文件不可篡改。

- 默认启用强防护（`chattr +i`）
- 支持严格全锁模式
- 支持 MACCMS 兼容模式
- 支持 Web UI 管理后台
- 支持 GitHub 一键安装

## 防护模式

1. 严格全锁模式
- 对站点扫描到的全部文件执行 `chattr +i`

2. MACCMS 兼容模式
- 自动跳过以下目录：
- `/runtime/`
- `/cache/`
- `/static/upload/`
- `/upload/`
- 其余文件执行 `chattr +i`

## 项目结构

```text
MacCmsWall
├── install.sh
├── uninstall.sh
├── README.md
├── panel/
│   ├── info.json
│   ├── index.html
│   ├── main.py
│   ├── static/
│   │   ├── style.css
│   │   └── app.js
│   ├── templates/
│   └── data/
├── scripts/
│   ├── common.sh
│   ├── lock.sh
│   ├── unlock.sh
│   ├── scan.sh
│   └── restore.sh
├── database/
│   └── init.sql
└── logs/
```

## 安装

```bash
curl -fsSL https://github.com/xxx/MacCmsWall/raw/main/install.sh | bash
```

脚本能力：

- 自动识别 BT / aaPanel
- 自动安装依赖（git/curl/sqlite3/python3/e2fsprogs）
- 自动拉取并部署插件
- 自动初始化数据库
- 自动尝试重启面板

## 卸载

```bash
bash /www/server/panel/plugin/MacCmsWall/uninstall.sh
```

卸载行为：

- 自动尝试解锁已保护站点
- 备份数据库与日志到 `/tmp/MacCmsWall_backup_时间戳`
- 删除插件目录
- 自动尝试重启面板

## API 概览（panel/main.py）

- `health`
- `get_modes`
- `get_dashboard`
- `list_sites`
- `add_site`
- `update_mode`
- `enable_protection`
- `disable_protection`
- `rescan_site`
- `relock_site`
- `remove_site`
- `get_logs`
- `clear_logs`

## 开发说明

- 后端：Python3 + SQLite
- 前端：HTML + CSS + JavaScript
- 防护：Shell 调用 `chattr`
- 默认目录：`/www/server/panel/plugin/MacCmsWall`

> 注意：`chattr +i` 依赖底层文件系统支持（常见 ext4/xfs 等环境请先验证）。
