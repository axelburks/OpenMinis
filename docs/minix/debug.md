# Minix Debug 构建

统一使用 [`scripts/minix-debug.sh`](../../scripts/minix-debug.sh)。
新电脑首次初始化使用 `scripts/minix-bootstrap.sh ios|android|both`；它会先准备
submodule、native 依赖和缺失的配置模板。

## Android

前置条件：

- `scripts/.env` 已配置 `MINIX_ANDROID_ENV`。
- Android SDK/NDK 已安装。
- JDK 17 已安装；脚本自动查找。

```sh
scripts/minix-debug.sh android
scripts/minix-debug.sh android --install
scripts/minix-debug.sh android --install --device SERIAL
scripts/minix-test.sh android
```

脚本会检测系统安装器并自动确认 Minix 的“安装/继续”操作；120 秒内仍未完成
则失败，不要求操作者守在设备旁。APK 输出到：

```text
build/debug/Minix-debug.apk
```

Debug、Perf、Release 使用同一持久签名，在 `versionCode` 不降低时可以互相
覆盖升级。

## iOS

编译：

```sh
scripts/minix-debug.sh ios
```

构建、安装并启动：

```sh
scripts/minix-debug.sh ios --install --device UDID
scripts/minix-test.sh ios --device UDID
```

## Android 构建变体

| 变体 | debuggable | DEV_TOOLS | R8/minify | 用途 |
|---|---:|---:|---:|---|
| Debug | 是 | 是 | 否 | 日常开发 |
| Perf | 否 | 是 | 否 | 性能测量 |
| Release | 否 | 否 | 是 | 正式分发 |

Release 使用 [`scripts/minix-release.sh`](../../scripts/minix-release.sh)。
