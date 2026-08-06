#!/bin/bash
# ============================================================================
# minix-sync.sh — 将 minix 分支同步到最新上游代码,并按需重编 native deps
# ============================================================================
#
# 工作流前提:
#   - origin = 你的 fork(axelburks/OpenMinis)。GitHub 网页端 "Sync fork"
#     会把官方 OpenMinis 的更新同步到 origin/main。
#   - main   = 官方镜像(只读,不在其上做改动)。
#   - minix  = 你的定制分支(Minix 改名 / 分享 scheme / AGENTS.md 等)。
#
# 本脚本做的事(全自动,除非遇到冲突):
#   1. 前置检查:工作区干净、当前可切分支。
#   2. 拉取 main(origin 已由 GitHub 自动同步官方)。
#   3. 记录 merge 前的 submodule 指针。
#   4. 切到 minix,merge main。
#      - 若冲突:输出完整冲突信息后退出(码 10),交给调用者/agent 解决。
#   5. 运行 Minix 静态守卫,捕获无冲突但恢复了已删除逻辑的上游改动。
#   6. 若 submodule 指针变化(ish/proot),同步 submodule 并按需重编对应 deps:
#      - deps/ish   变 → build_ish.sh (+ 需要时 prepare_alpine_rootfs.sh)
#      - deps/proot 变 → build_proot.sh
#   7. 末尾跑一次不签名 xcodebuild 验证依赖链完整(可用 --no-verify 跳过)。
#
# 环境处理(无需你在 shell 里手动 export):
#   - 编译 iSH VDSO 需要 LLVM 的 ld.lld;脚本内部把 /opt/homebrew/opt/lld/bin
#     前置进 PATH。
#   - build_ffmpeg.sh 的 `sed -i ''` 是 BSD 语法;脚本把 /usr/bin 前置进 PATH,
#     确保用系统 BSD sed 而非 PATH 里可能存在的 GNU sed。
#
# 退出码:
#   0  成功(可能无更新,幂等)
#   10 merge 冲突,需人工/agent 解决(已输出冲突详情)
#   20 submodule 同步失败
#   30 deps 重编失败
#   40 xcodebuild 验证失败
#   50 Minix 静态守卫失败,需审查上游 diff
#   1  其他前置检查失败
#
# 用法:
#   ./scripts/minix-sync.sh              # 完整流程
#   ./scripts/minix-sync.sh --no-verify  # 跳过末尾 xcodebuild 验证
#   ./scripts/minix-sync.sh --no-build   # 只做 git 同步,不碰 deps/xcodebuild
# ============================================================================

set -uo pipefail

# --- 配置 ---
MAIN_BRANCH="main"
WORK_BRANCH="minix"
LLD_BIN="/opt/homebrew/opt/lld/bin"

# --- 参数 ---
DO_VERIFY=1
DO_BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-verify) DO_VERIFY=0 ;;
        --no-build)  DO_BUILD=0 ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $arg (用 --help 查看用法)"; exit 1 ;;
    esac
done

# --- 定位仓库根(脚本在 scripts/ 下) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# --- 环境隔离:BSD sed(/usr/bin) + lld 前置 ---
export PATH="/usr/bin:$LLD_BIN:$PATH"

# --- 颜色/日志 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
ok()      { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()     { echo -e "${RED}❌ $1${NC}"; }
section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; }

# ============================================================================
# 1. 前置检查
# ============================================================================
section "1/7 前置检查"

# 未提交改动会被 merge/checkout 干扰,直接停
if ! git diff --quiet || ! git diff --cached --quiet; then
    err "工作区有未提交改动,请先提交或 stash 后再运行:"
    git status --short | grep -vE '^\?\?' | head -20
    exit 1
fi
ok "工作区干净"

# 确认两个分支都存在
for b in "$MAIN_BRANCH" "$WORK_BRANCH"; do
    if ! git show-ref --verify --quiet "refs/heads/$b"; then
        err "本地分支 '$b' 不存在。请先创建。"
        exit 1
    fi
done
ok "分支 $MAIN_BRANCH / $WORK_BRANCH 均存在"

ORIGINAL_BRANCH="$(git branch --show-current)"

# ============================================================================
# 2. 拉取 main
# ============================================================================
section "2/7 拉取 $MAIN_BRANCH(origin 已由 GitHub 同步官方)"

git checkout "$MAIN_BRANCH" || { err "切到 $MAIN_BRANCH 失败"; exit 1; }
MAIN_BEFORE="$(git rev-parse HEAD)"

if ! git pull --ff-only origin "$MAIN_BRANCH"; then
    err "git pull 失败。若提示非 fast-forward,说明本地 $MAIN_BRANCH 被改过(不该发生)。"
    err "排查:git log origin/$MAIN_BRANCH..$MAIN_BRANCH"
    exit 1
fi
MAIN_AFTER="$(git rev-parse HEAD)"

if [ "$MAIN_BEFORE" = "$MAIN_AFTER" ]; then
    info "$MAIN_BRANCH 无新提交。"
else
    ok "$MAIN_BRANCH 已更新:$(git rev-parse --short "$MAIN_BEFORE") → $(git rev-parse --short "$MAIN_AFTER")"
fi

# ============================================================================
# 3. 记录 merge 前的 submodule 指针
# ============================================================================
section "3/7 记录 submodule 指针(merge 前)"

ISH_BEFORE="$(git rev-parse HEAD:deps/ish 2>/dev/null || echo none)"
PROOT_BEFORE="$(git rev-parse HEAD:deps/proot 2>/dev/null || echo none)"
info "deps/ish   @ ${ISH_BEFORE:0:12}"
info "deps/proot @ ${PROOT_BEFORE:0:12}"

# ============================================================================
# 4. 切到 minix 并 merge main
# ============================================================================
section "4/7 merge $MAIN_BRANCH → $WORK_BRANCH"

git checkout "$WORK_BRANCH" || { err "切到 $WORK_BRANCH 失败"; exit 1; }

if [ "$MAIN_BEFORE" = "$MAIN_AFTER" ]; then
    # main 没变,检查 minix 是否已包含 main(可能之前合过)
    if git merge-base --is-ancestor "$MAIN_BRANCH" "$WORK_BRANCH"; then
        ok "$WORK_BRANCH 已包含最新 $MAIN_BRANCH,无需合并。"
    fi
fi

if git merge --no-edit "$MAIN_BRANCH"; then
    ok "merge 成功(或已是最新)。"
else
    # 冲突:输出详情后停下,交给 agent
    echo ""
    err "═══════════════════════════════════════════════════════════"
    err " MERGE 冲突 — 需要人工/agent 解决,脚本已停止"
    err "═══════════════════════════════════════════════════════════"
    echo ""
    warn "冲突文件列表:"
    git diff --name-only --diff-filter=U | sed 's/^/    /'
    echo ""
    warn "冲突详情(每个文件的 <<<<<<< / ======= / >>>>>>> 区块):"
    for f in $(git diff --name-only --diff-filter=U); do
        echo ""
        echo -e "${YELLOW}──── $f ────${NC}"
        # 只打印含冲突标记及其上下文,避免刷屏
        grep -n -A2 -B2 -E '^(<<<<<<<|=======|>>>>>>>)' "$f" | head -60
    done
    echo ""
    warn "解决指引:"
    echo "    - Minix 定制冲突(bundle id / App Group group.com.axel.minix /"
    echo "      iCloud iCloud.com.axel.minix / 显示名 Minix / minix:// scheme /"
    echo "      请求自定义与语义思考强度):"
    echo "      保留 minix 侧(HEAD)的值。"
    echo "    - 其他纯官方逻辑改动:通常接受 main 侧。"
    echo "    - 解决后重新运行本脚本以完成 submodule/deps 步骤。"
    echo "    - 放弃本次合并:git merge --abort"
    exit 10
fi

# ============================================================================
# 5. Minix 静态守卫
# ============================================================================
section "5/7 Minix 静态守卫"

if ! ./scripts/minix-check-invariants.sh; then
    err "Minix 静态守卫失败。上游可能无冲突地恢复了已删除逻辑。"
    err "请审查 git diff main...minix,按 AGENTS.md §1 保留 Minix 行为后重试。"
    exit 50
fi
ok "Minix 静态守卫通过。"

# ============================================================================
# 6. 检测 submodule 指针变化,按需同步 + 重编 deps
# ============================================================================
section "6/7 检测 submodule 变化并按需重编 deps"

if [ "$DO_BUILD" -eq 0 ]; then
    warn "--no-build:跳过 submodule 同步与 deps 重编。"
else
    ISH_AFTER="$(git rev-parse HEAD:deps/ish 2>/dev/null || echo none)"
    PROOT_AFTER="$(git rev-parse HEAD:deps/proot 2>/dev/null || echo none)"

    NEED_ISH=0
    NEED_PROOT=0
    [ "$ISH_BEFORE" != "$ISH_AFTER" ] && NEED_ISH=1
    [ "$PROOT_BEFORE" != "$PROOT_AFTER" ] && NEED_PROOT=1

    # deps 产物缺失也触发重编(首次或被清理过)
    [ ! -f "deps/libs/libish.a" ] && NEED_ISH=1

    if [ "$NEED_ISH" -eq 0 ] && [ "$NEED_PROOT" -eq 0 ]; then
        ok "submodule 指针无变化,deps 无需重编。"
    else
        info "同步 submodule 工作区到记录的 commit..."
        if ! git submodule update --init --recursive; then
            err "git submodule update 失败。"
            exit 20
        fi
        ok "submodule 已同步。"

        if [ "$NEED_ISH" -eq 1 ]; then
            info "deps/ish 变化(${ISH_BEFORE:0:12} → ${ISH_AFTER:0:12})或产物缺失 → 重编 iSH"
            if [ ! -x "$LLD_BIN/ld.lld" ]; then
                err "缺少 ld.lld($LLD_BIN)。请先: brew install lld"
                exit 30
            fi
            if ! ./deps/build_ish.sh; then
                err "build_ish.sh 失败。"
                exit 30
            fi
            ok "iSH 重编完成。"
            # rootfs 通常不随 ish 变;如遇 fakefs 格式变更导致运行异常,再手动跑:
            #   ./deps/prepare_alpine_rootfs.sh
        fi

        if [ "$NEED_PROOT" -eq 1 ]; then
            info "deps/proot 变化(${PROOT_BEFORE:0:12} → ${PROOT_AFTER:0:12}) → 重编 PRoot"
            if [ -z "${ANDROID_NDK_HOME:-}" ]; then
                warn "未设置 ANDROID_NDK_HOME,跳过 PRoot 重编。"
                warn "如需 Android:export ANDROID_NDK_HOME=... 后手动跑 ./deps/build_proot.sh"
            elif ! ./deps/build_proot.sh; then
                err "build_proot.sh 失败。"
                exit 30
            else
                ok "PRoot 重编完成。"
            fi
        fi
    fi
fi

# ============================================================================
# 7. 不签名 xcodebuild 验证依赖链
# ============================================================================
section "7/7 xcodebuild 验证(不签名)"

if [ "$DO_VERIFY" -eq 0 ] || [ "$DO_BUILD" -eq 0 ]; then
    warn "跳过 xcodebuild 验证。"
else
    info "编译验证依赖链(CODE_SIGNING_ALLOWED=NO,generic/platform=iOS)..."
    if xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis \
                  -configuration Debug -destination 'generic/platform=iOS' \
                  CODE_SIGNING_ALLOWED=NO build >/tmp/minix-sync-xcodebuild.log 2>&1; then
        ok "xcodebuild 依赖链验证通过。"
    else
        err "xcodebuild 失败。末尾日志:"
        tail -40 /tmp/minix-sync-xcodebuild.log
        err "完整日志:/tmp/minix-sync-xcodebuild.log"
        exit 40
    fi
fi

# ============================================================================
# 完成
# ============================================================================
section "完成"
ok "minix 已同步到最新上游。"
echo ""
info "当前分支:$(git branch --show-current)"
info "最近提交:$(git log --oneline -1)"
[ "$ORIGINAL_BRANCH" != "$WORK_BRANCH" ] && warn "注意:你原本在 '$ORIGINAL_BRANCH',现在停在 '$WORK_BRANCH'。"
echo ""
info "如需推送:git push origin $WORK_BRANCH"
