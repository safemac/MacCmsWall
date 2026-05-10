# MacCmsWall

MacCmsWall 是一个基于 Linux chattr +i 的网站防篡改插件，面向 BT / aaPanel 第三方插件部署场景。

## 一键命令（默认智能）

```bash
curl -fsSL https://raw.githubusercontent.com/safemac/MacCmsWall/main/onekey.sh | bash
```

默认行为：

- 未安装时自动安装
- 已安装时自动更新
- 自动识别 BT / aaPanel
- 自动执行 MD5 完整性校验

可选指定动作：

```bash
MACCMSWALL_ACTION=install curl -fsSL https://raw.githubusercontent.com/safemac/MacCmsWall/main/onekey.sh | bash
MACCMSWALL_ACTION=update curl -fsSL https://raw.githubusercontent.com/safemac/MacCmsWall/main/onekey.sh | bash
MACCMSWALL_ACTION=uninstall curl -fsSL https://raw.githubusercontent.com/safemac/MacCmsWall/main/onekey.sh | bash
```

## 防护模式

1. 严格全锁模式
- 对站点扫描到的全部文件执行 chattr +i

2. MACCMS 兼容模式
- 自动跳过目录：
- /runtime/
- /cache/
- /static/upload/
- /upload/
- 其余文件执行 chattr +i

## 项目结构

```text
MacCmsWall
├── checksums.md5
├── onekey.sh
├── install.sh
├── update.sh
├── uninstall.sh
├── README.md
├── panel/
│   ├── info.json
│   ├── main.py
│   ├── index.html
│   ├── icon.png
│   ├── static/
│   ├── templates/
│   └── data/
├── scripts/
│   ├── common.sh
│   ├── lock.sh
│   ├── unlock.sh
│   ├── scan.sh
│   ├── restore.sh
│   ├── release_skill.sh
│   └── build_release.sh
├── database/
│   └── init.sql
├── logs/
└── dist/
```

## 执行链路

- onekey.sh：统一入口，自动判断 install / update / uninstall
- install.sh：安装与升级部署（带数据保留）
- update.sh：拉取新版本后复用 install.sh 升级
- uninstall.sh：卸载前自动尝试解锁并备份数据

## MD5 完整性策略

- onekey.sh、install.sh、update.sh 在执行关键脚本前，会读取 checksums.md5 做显式 MD5 校验
- 校验失败（疑似被篡改）会立即拒绝执行
- 打包阶段自动刷新 checksums.md5，避免发布脚本哈希过期

## 打包 Skill

- scripts/release_skill.sh：封装打包时的自动化逻辑
- scripts/build_release.sh：调用 release_skill.sh，执行完整分发构建

每次打包自动完成：

- 刷新根目录 checksums.md5
- 生成 dist/MacCmsWall-vX.Y.Z.md5
- 生成 dist/MacCmsWall-vX.Y.Z.sha256
- 自动更新本 README 的 Release Auto Info 区块

## 分发构建

```bash
bash scripts/build_release.sh
```

产物：

- MacCmsWall-vX.Y.Z.zip
- MacCmsWall-vX.Y.Z.tar.gz
- MacCmsWall-vX.Y.Z.md5
- MacCmsWall-vX.Y.Z.sha256

## Release Auto Info
<!-- RELEASE_AUTO_START -->
- Last release: v1.3.1
- Built at: 2026-05-10 19:39:00 +08:00
- One line command:

```bash
curl -fsSL https://raw.githubusercontent.com/safemac/MacCmsWall/main/onekey.sh | bash
```

- MD5
```text
f44923f8dc8a043e29dc67bbb4923732  MacCmsWall-v1.3.1.zip
db9bb19495a53e6ae6027b6e09c9c8ef  MacCmsWall-v1.3.1.tar.gz
```

- SHA256
```text
2039d12a575bcc719a79afdccebb965da6fa44048231dfe85c8dbfe7caf12b15  MacCmsWall-v1.3.1.zip
b83f8e8350184b5fecfcdffe55c18c6fb75052a26d8633c193737413832c20ca  MacCmsWall-v1.3.1.tar.gz
```
<!-- RELEASE_AUTO_END -->

> 注意：chattr +i 依赖底层文件系统支持（例如 ext4/xfs），请先在目标服务器验证。
