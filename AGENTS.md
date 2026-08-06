# AGENTS.md — OpenMinis / Minix 开发指南

> 本仓库是官方 OpenMinis 的 fork,定制为 **Minix**(与原版共存)。

---

## 0. 项目

**OpenMinis** = 设备端私有 AI Agent App,iOS(Swift/SwiftUI)+ Android(Kotlin/Compose)双端原生。核心:BYO 模型(Anthropic/OpenAI/Gemini/xAI/Kimi/OpenRouter…)+ 设备内 Linux 沙箱(iOS=iSH,Android=PRoot)+ 原生能力 offload + 浏览器自动化 + skills + memory。

**布局**:`src/ios/`(+ Share/Widget/FileProvider 扩展) · `src/android/`(+ JNI cpp) · `src/shared/` · `deps/`(native 构建脚本 + ish/proot submodule) · `docs/specs/` · `scripts/`。

---

## 1. Minix 定制领域(合并冲突判定 + 改动雷区)

**冲突原则**:定制处保留 minix 侧(ours/HEAD),其余纯官方逻辑改动接受上游(theirs/main)。

**权威依据**(本文件不堆细节,避免与下列来源漂移):
- **哪些行为必须保留** → `./scripts/minix-check-invariants.sh`(机器可执行的防回归断言,是唯一硬约束)。
- **每条需求的完整需求/技术设计** → `docs/minix/`。
- **代码落点** → 关键处带 `[Minix]` 注释(`grep -rn "\[Minix\]" src/`);标识符 `grep -rn "axel.minix" src/` 或 `git diff main...minix`。

**定制领域**(类目稳定;**新需求归入已有领域,勿逐条往下堆行**。改到某领域的红线前先读对应 doc):
- **与原版共存**:改 Bundle ID/`applicationId` → `com.axel.minix`、App Group/iCloud 容器、`minix://` 深链、可见文案 Minis→Minix;不覆盖原版 `com.openminis.app`。→ [coexistence.md](docs/minix/coexistence.md)
- **请求自定义**:Provider/模型支持自定义 Header+Body,模型另有 Request Controls;自研表达式引擎(非 JS,独立于 `MinixRequestExpression.*`)。**红线**:不恢复原版专用 User-Agent 字段;OAuth 路径同样应用定制且之后不恢复默认。→ [请求自定义](docs/minix/provider-model-request-customization-requirements.md) · [表达式](docs/minix/request-expression-language-requirements.md)
- **语义思考强度 & 聊天 Request Controls**:思考档位以不可变 `definitionId` 为持久引用;聊天弹层实现独立于原版(`MinixChatRequestControls.*`)。**红线**:不恢复按厂商/baseURL/model-id 的 thinking 注入分支。→ [Request Controls](docs/minix/request-controls-requirements.md)

⚠️ **改到上述领域**(Provider 请求构建、thinking 默认注入、配置持久化、模型 fallback、聊天输入弹层)→ 先跑 `./scripts/minix-check-invariants.sh`,再跑相关真机单测/UI 测试。**不得用新命名绕过守卫来恢复被禁行为。**

---

## 2. 分支与同步

- **`main`** = 官方镜像(只读) · **`minix`** = 定制分支(§1 改动都在这)。
- 同步上游跑 `./scripts/minix-sync.sh`。遇冲突或静态守卫失败时脚本会停下并输出冲突文件、区块与解决指引——按其提示、依 §1 原则处理后重跑。即使 merge 无冲突也不代表安全:上游可能在别处重新加入已删逻辑,以守卫结果为准。

---

## 3. 构建 & 测试

- **iOS 编译验证**:`xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`。
  **⚠️ 单测必须真机**:native deps 只编译真机 arm64,模拟器链接会失败。
- **Android**:`cd src/android && ./gradlew :app:assembleDebug`;单测 `./gradlew :app:testDebugUnitTest`,装机 `./gradlew :app:installDebug`。
- **发布**:`./scripts/minix-release.sh`,流程见 [release.md](docs/minix/release.md)。

---

## 4. 工作约定

- **改动最小化**:只改必要处、遵循既有风格,不顺手重构无关代码;发现无关问题单独提出。
- **双端对称**:跨端功能默认 iOS + Android 两侧对称(可先改 iOS 验证);Android 代码大量标 `Mirrors iOS ...`,先查对端实现。
- **调试**:iOS 内建 DebugServer,见 [debug-server-api.md](docs/specs/debug-server-api.md)。

---

## 5. 深入阅读

- **架构/实现细节**(Provider 抽象层、消息格式、thinking 适配、沙箱、offload、双端对称表、scripts 说明)→ [architecture.md](docs/architecture.md)
- **构建全流程** → [BUILDING.md](BUILDING.md);**发布** → [release.md](docs/minix/release.md)
- **接口规范** → `docs/specs/`(minis-url-scheme / ios-sandbox-ish-summary / debug-server-api)
- **Minix 定制文档** → `docs/minix/`(共存 · 请求自定义 · Request Controls · 表达式,各含需求与技术设计)
