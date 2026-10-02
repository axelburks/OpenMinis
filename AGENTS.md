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
- **请求自定义**:Provider/模型支持自定义 Header+Body,模型另有 Request Controls;自研表达式引擎(非 JS,独立于 `MinixRequestExpression.*`)。**红线**:不恢复原版专用 User-Agent 字段;OAuth 路径同样应用定制且之后不恢复默认。→ [请求自定义](docs/minix/request-customization-prd.md) · [表达式](docs/minix/exp-lang-prd.md)
- **语义思考强度 & 聊天 Request Controls**:思考档位以不可变 `definitionId` 为持久引用;聊天弹层实现独立于原版(`MinixChatRequestControls.*`)。**红线**:保留上游 `ThinkingRuleResolver`（含用户规则、DB/UI/同步/备份）；Provider 主体不得重复散落 resolver 已拥有的厂商分支；启用 Minix 语义思考控制时必须跳过 resolver/协议默认 thinking 注入。→ [Request Controls](docs/minix/request-controls-prd.md)
- **内置工具中立管线**:服务端内置工具项以中立类型 `AgentNativeItem` 原样采集/展示/回传,详见文档。→ [内置工具](docs/minix/builtin-tools-prd.md)

⚠️ **改到上述领域**(Provider 请求构建/输出解析、thinking 默认注入、配置持久化、模型 fallback、聊天输入弹层、内置工具采集与回传)→ 先跑 `./scripts/minix-check-invariants.sh`,再跑相关真机单测/UI 测试。**不得用新命名绕过守卫来恢复被禁行为。**

---

## 2. 分支与同步

- **`main`** = 官方镜像(只读) · **`minix`** = 定制分支(§1 改动都在这)。
- 同步上游跑 `./scripts/minix-sync.sh [ios|android|both]`。它只编排 Git、静态守卫、统一依赖协调和构建验证,不得在其中维护单项 native 依赖规则。遇冲突时按 §1 解决并 `git add`,再原命令重跑,脚本会继续现有 merge。
- **Agent 合并审计与验证**:staged/unstaged 三方检查、停止条件、双端测试和真机安装命令见 [merge-playbook.md](docs/minix/merge-playbook.md)。

---

## 3. 构建 & 测试

- **新机初始化**:`./scripts/minix-bootstrap.sh ios|android|both`;不要用 `minix-sync.sh` 代替初始化。
- **native 依赖**:`./scripts/minix-deps.sh ios|android|both`;该脚本中的组件输入/输出清单是唯一入口,新增 `deps/build_*.sh` 必须同步登记,不得把依赖判断散落回 sync/bootstrap。
- **iOS**:构建/装机走 `./scripts/minix-debug.sh ios [--install --device UDID]`;单测走 `./scripts/minix-test.sh ios --device UDID`。**单测必须真机**:native deps 只编译真机 arm64。
- **Android**:构建/装机走 `./scripts/minix-debug.sh android [--install --device SERIAL]`;单测走 `./scripts/minix-test.sh android`。流程见 [debug.md](docs/minix/debug.md)。
- **发布**:`./scripts/minix-release.sh`,流程见 [release.md](docs/minix/release.md)。

---

## 4. 工作约定

- **改动最小化**:只改必要处、遵循既有风格,不顺手重构无关代码;发现无关问题单独提出。
- **上游脚本最小侵入**:Minix 初始化/同步/依赖兼容逻辑优先放 `scripts/minix-*.sh`;除非修复无法在外层编排且明确应上游化,不要改 `deps/` 或其他随上游同步的构建脚本。
- **代码及注释**:逻辑独立时可适当拆分出 `Minix*` 文件，少量接线/分支不强拆。内联修改官方文件时，每个独立逻辑块至少一处 `[Minix]` 注释，连续多行共享一处即可。
- **双端对称**:跨端功能默认 iOS + Android 两侧对称(可先改 iOS 验证);Android 代码大量标 `Mirrors iOS ...`,先查对端实现。
- **调试**:iOS 内建 DebugServer,见 [debug-server-api.md](docs/specs/debug-server-api.md)。

---

## 5. 深入阅读

- **架构/实现细节**(Provider 抽象层、消息格式、thinking 适配、沙箱、offload、双端对称表、scripts 说明)→ [architecture.md](docs/architecture.md)
- **构建全流程** → [BUILDING.md](BUILDING.md);**发布** → [release.md](docs/minix/release.md)
- **接口规范** → `docs/specs/`(minis-url-scheme / ios-sandbox-ish-summary / debug-server-api)
- **Minix 定制文档** → `docs/minix/`(共存 · 请求自定义 · Request Controls · 表达式 · 内置工具,各含需求与技术设计)
