# Minix 上游合并与验证

## 合并

```sh
./scripts/minix-sync.sh both
```

脚本遇到冲突会停止。解决冲突并 `git add` 后重跑同一命令，脚本会识别
`MERGE_HEAD`、完成现有 merge，再继续守卫、依赖协调和构建验证。解决时：

1. Minix 定制领域保留 `HEAD` 语义。
2. 其他业务逻辑接受 `main`。
3. 只做连接两侧所需的最小适配。
4. 两侧都没有的新行为必须单独确认，不得混入 merge。

## 三方检查

merge 中的 staged 包含自动合并结果和已解决冲突，不能只检查 unstaged：

```sh
git status
git diff --cached --name-status
git diff --name-status

BASE="$(git merge-base HEAD MERGE_HEAD)"
git diff --name-only "$BASE" HEAD
git diff --name-only "$BASE" MERGE_HEAD
git diff main
git diff AUTO_MERGE
```

优先检查：

- `.git/MERGE_MSG` 中的冲突文件。
- 两个父分支都修改过的文件。
- 最终结果相对 `main` 新增、但合并前 Minix 没有的行为。
- `AUTO_MERGE` 后人工修改过的生产代码。

## 静态验证

```sh
./scripts/minix-check-invariants.sh
git diff HEAD --check
git diff --cached --diff-filter=U --name-only
```

## Android

单测：

```sh
scripts/minix-test.sh android
scripts/minix-test.sh android --tests '完整测试类名'
```

构建或装机：

```sh
scripts/minix-debug.sh android
scripts/minix-debug.sh android --install --device SERIAL
```

Instrumentation 测试必须确认 APK 已完成设备端安装。测试挂起时先检查设备是否
冻结目标进程。

## iOS

单测必须使用真机：

```sh
scripts/minix-test.sh ios --device UDID
scripts/minix-test.sh ios --device UDID \
  --only-testing MinisTests/SuiteName
```

构建或装机：

```sh
scripts/minix-debug.sh ios
scripts/minix-debug.sh ios --install --device UDID
```

## 完成标准

- 无冲突文件和冲突标记。
- 所有偏离 `main` 的生产行为都有 Minix 文档或明确决策依据。
- invariants、Android 全量单测、iOS 编译通过。
- 涉及请求链或 UI 时，相关真机测试通过。
