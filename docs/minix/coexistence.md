# Minix 与原版共存

Minix 是官方 OpenMinis 的定制分支，目标是**能与 App Store / Play 上的原版 `com.openminis.app` 并存安装、互不覆盖**。为此改动了一批身份标识与用户可见文案；本文件是这批改动的完整清单，也是合并上游冲突时判断"该保留 Minix 侧"的依据。

## 改了什么（保留 Minix 侧）

- **Bundle ID / applicationId**：iOS 6 个 target 的 Bundle ID、Android 的 `applicationId` 全部改为 `com.axel.minix`。
- **App Group / iCloud 容器**：iOS 的 App Group 与 iCloud 容器标识改为 `*.axel.minix`。
- **深链 scheme**：双端新增独占深链 `minix://`；同时**保留** `minis://` 供进程内资源 URL 使用（不是对外深链，不能删）。
- **用户可见文案**：显示名、AppShortcuts、Android `app_name` 中的 "Minis" → "Minix"。
- **构建注入值**：填入了 `ANTHROPIC_OAUTH_IDENTIFIER_PROMPT` 的构建值。

## 不改（靠机制自动隔离）

以下 App 内部标识**故意保持原样**，因为沙箱 / access-group / `${applicationId}` 会自动隔离两个 App，改了反而增加与上游的无谓冲突：

- iOS：Keychain service 名、`os_log` subsystem、缓存目录名。
- Android：`namespace`、`package`、JNI 符号、内部 action / prefs 名。

## 快速定位

- 关键定制处带 `[Minix]` 注释：`grep -rn "\[Minix\]" src/`
- 定制标识符全量：`grep -rn "axel.minix" src/`
- 相对上游的完整改动：`git diff main...minix`
