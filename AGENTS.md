# AGENTS.md — OpenMinis / Minix 开发指南

> 本仓库是官方 OpenMinis 的 fork,定制为 **Minix**(与原版共存)。
> **详细架构/实现** → 读 [docs/architecture.md](docs/architecture.md)。最后更新:2026-07-30。

---

## 0. 项目一句话

**OpenMinis** = 设备端私有 AI Agent App,iOS(Swift/SwiftUI ~187k 行)+ Android(Kotlin/Compose ~154k 行)双端原生。核心:BYO 模型(Anthropic/OpenAI/Gemini/xAI/Kimi/OpenRouter…)+ 设备内 Linux 沙箱(iOS=iSH,Android=PRoot)+ 原生能力 offload + 浏览器自动化 + skills + memory。

**仓库布局**:`src/ios/`(+ Share/Widget/FileProvider 扩展) · `src/android/`(+ JNI cpp) · `src/shared/` · `deps/`(native 构建脚本 + ish/proot submodule) · `docs/specs/` · `scripts/`。

---

## 1. ⭐ Minix 定制清单(相对原版的改动 —— 合并冲突时保留 ours 的依据)

> **冲突总原则**:本表列出的 Minix 定制**保留 axel 侧(ours)**;其余纯官方逻辑改动**接受上游(theirs)**。**一个需求一条**,后续新需求往下加。
> 落点不逐一罗列——关键定制处带 `[Minix]` 注释(`grep -rn "\[Minix\]" src/`);标识符全量看 `grep -rn "axel.minix" src/` 或 `git diff main...axel`。

| # | 需求 | 改了什么 |
|---|---|---|
| 1 | 与原版共存 | 为独立安装、不覆盖 App Store/Play 原版 `com.openminis.app`,改了一批 id/标志/文案:iOS 6 个 target Bundle ID·Android `applicationId` → `com.axel.minix`;iOS App Group·iCloud 容器 → `*.axel.minix`;双端新增独占深链 `minix://`(保留 `minis://` 供进程内资源 URL);用户可见文案 Minis → Minix(显示名/AppShortcuts/`app_name`)。并填入构建值 `ANTHROPIC_OAUTH_IDENTIFIER_PROMPT`。**App 内标识不改**(iOS Keychain service·os_log·缓存目录名;Android `namespace`·`package`·JNI 符号·内部 action/prefs 名——靠沙箱/access-group/`${applicationId}` 自动隔离)。 |

---

## 2. 分支模型与上游同步

- **`main`** = 官方镜像(只读)。origin = fork `axelburks/OpenMinis`,GitHub 网页端 "Sync fork" 把官方更新同步进 `origin/main`。
- **`axel`** = 定制分支(上面 §1 所有改动都在这)。
- **同步上游**:跑 `./scripts/update-axel.sh`。自动:拉 main → merge 到 axel → 检测 submodule 指针变化按需重编 deps(`deps/ish`→build_ish、`deps/proot`→build_proot)→ 不签名 xcodebuild 验证。
  - **冲突不自动解决**:输出冲突文件+区块后退出(码 10),交给 agent。按 §1 原则解决 → 重跑脚本。

---

## 3. 构建 & 发布

- **首次 native deps + 完整构建流程/环境** → [BUILDING.md](BUILDING.md)。
- **日常**:iOS 用 Xcode 开 `src/ios/Minis.xcodeproj` 真机 run;Android `cd src/android && ./gradlew :app:assembleDebug`。
- **发布**:一键脚本 `./scripts/release.sh`(细节看 `--help`):
  - `release.sh ios` → 归档上传 TestFlight 供自测;**自测 OK 后**再 `release.sh promote-ios` 提审+发**外部组**(**上传 ≠ 发布**)。
  - `release.sh android` → 签名 release APK。

---

## 4. 工作约定与陷阱

- **改动最小化**:只改必要处、遵循既有风格,不顺手重构无关代码;发现无关问题单独提出。
- **双端对称**:改跨端功能默认需 iOS + Android 两侧对称;可先改 iOS 验证,但**不能忘 Android 也要改和验证**(反之亦然)——一端改完不等于需求完成。Android 代码大量注释标 `Mirrors iOS ...`,先查对端实现。详见 [docs/architecture.md §5](docs/architecture.md)。
- **`Localizable.xcstrings` 会被 Xcode 自动改**(编译时重排/补词条),diff 大但无害,非手工改动;提交定制时可还原它避免污染。
- **调试**:iOS 内建 DebugServer(见 [docs/specs/debug-server-api.md](docs/specs/debug-server-api.md))。

---

## 5. 深入阅读

- **架构/实现细节**(Provider 抽象层、消息格式、thinking 适配、沙箱、offload、双端对称表、scripts 说明)→ [docs/architecture.md](docs/architecture.md)
- **构建全流程** → [BUILDING.md](BUILDING.md)
- **接口规范** → `docs/specs/`(minis-url-scheme / ios-sandbox-ish-summary / debug-server-api)
