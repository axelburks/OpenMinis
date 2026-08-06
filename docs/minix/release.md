# Minix 发布流程

发布统一走 [`scripts/minix-release.sh`](../../scripts/minix-release.sh);参数与细节见 `scripts/minix-release.sh --help`。

## 命令

```sh
scripts/minix-release.sh                   # iOS + Android 全构建
scripts/minix-release.sh ios               # iOS:归档 → 导出 → 上传 TestFlight
scripts/minix-release.sh android           # Android:签名 release APK
scripts/minix-release.sh --no-upload ios   # iOS:仅本地导出 IPA,不上传
scripts/minix-release.sh promote-ios       # 分配外部组 + 提交 beta 审核
```

## 约束

- **iOS 两步,上传 ≠ 发布**:`ios` 只上传 TestFlight 供自测;自测通过后才能 `promote-ios` 对外发布。两步之间必须有人工自测,不可省略或合并。
