#!/usr/bin/env bash
# [Minix] Reconcile native dependencies from source inputs.
#
#   scripts/minix-deps.sh ios|android|both
#   scripts/minix-deps.sh ios|android|both --force
#   scripts/minix-deps.sh ios|android|both --check
#
# --check (alias: --dry-run) reports stale components without changing files.
# State is stored under build/deps-state/ and is valid only while both the
# recorded source fingerprint and every declared output are present.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$REPO_ROOT/build/deps-state"
LOCK_DIR="$REPO_ROOT/build/deps-state.lock"
# Increment when reconciliation semantics change without a component input.
STATE_SCHEMA="1"
PLATFORM=""
FORCE=0
CHECK_ONLY=0

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/minix-android-toolchain.sh"

# FFmpeg's patch step requires BSD sed even when Homebrew GNU tools are present.
export PATH="/usr/bin:$PATH"

usage() {
  sed -n '2,10s/^# \{0,1\}//p' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    ios|android|both)
      [ -z "$PLATFORM" ] || { echo "platform specified more than once" >&2; exit 2; }
      PLATFORM="$1"
      ;;
    --force) FORCE=1 ;;
    --check|--dry-run) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

[ -n "$PLATFORM" ] || { usage; exit 2; }

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m[ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[stale] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

ensure_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command '$1': $2"
}

check_registered_builders() {
  local path name unknown=""
  while IFS= read -r path; do
    name="${path##*/}"
    case "$name" in
      build_ffmpeg.sh|build_ish.sh|build_lame.sh|build_proot.sh|build_rclone_android.sh|build_rclone_ios.sh) ;;
      *) unknown="${unknown}${unknown:+, }$name" ;;
    esac
  done <<EOF
$(find "$REPO_ROOT/deps" -maxdepth 1 -type f -name 'build_*.sh' -print | sort)
EOF
  [ -z "$unknown" ] || die "unregistered dependency builders: $unknown. Add each component to scripts/minix-deps.sh."
}

append_repo_inputs() {
  local file executable
  printf 'paths %s\n' "$*"
  while IFS= read -r -d '' file; do
    if [ ! -e "$REPO_ROOT/$file" ] && [ ! -L "$REPO_ROOT/$file" ]; then
      printf 'missing %s\n' "$file"
      continue
    fi
    executable=0
    [ -x "$REPO_ROOT/$file" ] && executable=1
    printf 'file %s executable=%s blob=%s\n' \
      "$file" "$executable" "$(git -C "$REPO_ROOT" hash-object -- "$file")"
  done < <(git -C "$REPO_ROOT" ls-files -co --exclude-standard -z -- "$@")
}

append_submodule_input() {
  local path="$1"
  if ! git -C "$REPO_ROOT/$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'missing-submodule %s\n' "$path"
    return
  fi
  printf 'submodule %s %s\n' "$path" "$(git -C "$REPO_ROOT/$path" rev-parse HEAD)"
  git -C "$REPO_ROOT/$path" status --porcelain=v1 --untracked-files=no
  git -C "$REPO_ROOT/$path" diff --binary --no-ext-diff HEAD
  git -C "$REPO_ROOT/$path" submodule status --recursive 2>/dev/null || true
}

component_signature() {
  local component="$1"
  {
    printf 'minix-deps-schema=%s\ncomponent=%s\n' "$STATE_SCHEMA" "$component"
    case "$component" in
      ios-lame)
        append_repo_inputs \
          deps/build_lame.sh \
          deps/lame-3.100 \
          ':(exclude,glob)deps/lame-3.100/**/*.o' \
          ':(exclude,glob)deps/lame-3.100/**/*.lo'
        ;;
      ios-ffmpeg)
        append_repo_inputs deps/build_ffmpeg.sh deps/ffmpeg-patch
        printf 'ios-lame=%s\n' "$(component_signature ios-lame)"
        ;;
      ios-ish)
        append_repo_inputs deps/build_ish.sh
        append_submodule_input deps/ish
        ;;
      ios-rootfs)
        append_repo_inputs deps/prepare_alpine_rootfs.sh
        printf 'ios-ish=%s\n' "$(component_signature ios-ish)"
        ;;
      ios-rclone)
        append_repo_inputs deps/build_rclone_ios.sh deps/rclone-mobile
        ;;
      android-proot)
        append_repo_inputs \
          deps/build_proot.sh \
          deps/talloc \
          scripts/minix-android-toolchain.sh \
          src/android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so \
          src/android/app/src/main/jniLibs/arm64-v8a/libproot-loader32.so
        append_submodule_input deps/proot
        ;;
      android-rootfs)
        append_repo_inputs scripts/prepare_android_sandbox.sh
        ;;
      android-rclone)
        append_repo_inputs \
          deps/build_rclone_android.sh \
          deps/rclone-mobile \
          scripts/minix-android-toolchain.sh
        ;;
      *)
        die "unknown dependency component: $component"
        ;;
    esac
  } | shasum -a 256 | awk '{print $1}'
}

component_outputs() {
  case "$1" in
    ios-lame)
      printf '%s\n' \
        deps/lame-build/lib/libmp3lame.a \
        deps/lame-build/include/lame/lame.h
      ;;
    ios-ffmpeg)
      printf '%s\n' \
        deps/frameworks/FFmpeg.framework/FFmpeg \
        deps/frameworks/libavcodec.framework/libavcodec \
        deps/frameworks/libavformat.framework/libavformat \
        deps/frameworks/libavutil.framework/libavutil \
        deps/frameworks/libavfilter.framework/libavfilter \
        deps/frameworks/libswresample.framework/libswresample \
        deps/frameworks/libswscale.framework/libswscale
      ;;
    ios-ish)
      printf '%s\n' \
        deps/libs/libish.a \
        deps/libs/libish_emu.a \
        deps/libs/libfakefs.a \
        deps/include/ish/ish.h \
        deps/resources/libvdso.so.elf \
        deps/resources/RootfsPatch.bundle/manifest.plist
      ;;
    ios-rootfs)
      printf '%s\n' deps/resources/alpine-rootfs.zip
      ;;
    ios-rclone)
      printf '%s\n' \
        deps/frameworks/Rclone.xcframework/Info.plist \
        deps/frameworks/Rclone.xcframework/ios-arm64/librclone.a \
        deps/frameworks/Rclone.xcframework/ios-arm64-simulator/librclone.a
      ;;
    android-proot)
      printf '%s\n' \
        src/android/app/src/main/assets/proot-aarch64 \
        src/android/app/src/main/jniLibs/arm64-v8a/libproot.so \
        src/android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so \
        src/android/app/src/main/jniLibs/arm64-v8a/libproot-loader32.so
      ;;
    android-rootfs)
      printf '%s\n' src/android/app/src/main/assets/alpine-minirootfs.tar.gz
      ;;
    android-rclone)
      printf '%s\n' src/android/app/libs/rclone.aar
      ;;
  esac
}

outputs_present() {
  local component="$1" output
  MISSING_OUTPUT=""
  while IFS= read -r output; do
    if [ ! -s "$REPO_ROOT/$output" ]; then
      MISSING_OUTPUT="$output"
      return 1
    fi
  done <<EOF
$(component_outputs "$component")
EOF
}

component_is_current() {
  local component="$1" signature="$2" state_file="$STATE_DIR/$component.sha256" recorded=""
  if ! outputs_present "$component"; then
    STALE_REASON="missing output $MISSING_OUTPUT"
    return 1
  fi
  if [ ! -f "$state_file" ]; then
    STALE_REASON="no recorded source fingerprint"
    return 1
  fi
  recorded="$(cat "$state_file")"
  if [ "$recorded" != "$signature" ]; then
    STALE_REASON="source fingerprint changed"
    return 1
  fi
  if [ "$FORCE" -eq 1 ]; then
    STALE_REASON="forced rebuild"
    return 1
  fi
  return 0
}

ensure_go_125() {
  local version numeric major minor
  ensure_command go "install Go 1.25 or newer"
  version="$(go env GOVERSION 2>/dev/null || true)"
  numeric="${version#go}"
  major="${numeric%%.*}"
  minor="${numeric#*.}"
  minor="${minor%%.*}"
  case "$major:$minor" in
    *[!0-9:]*|:*) die "unable to determine Go version from '$version'" ;;
  esac
  if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 25 ]; }; then
    die "Go 1.25 or newer is required; found $version"
  fi
}

ensure_lld() {
  local candidate
  if command -v ld.lld >/dev/null 2>&1; then
    return
  fi
  for candidate in /opt/homebrew/opt/lld/bin /usr/local/opt/lld/bin; do
    if [ -x "$candidate/ld.lld" ]; then
      export PATH="$candidate:$PATH"
      return
    fi
  done
  die "ld.lld is required for the iSH VDSO; install it with: brew install lld"
}

ensure_android_native_toolchain() {
  local status
  : "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  [ -d "$ANDROID_HOME" ] || die "Android SDK not found at $ANDROID_HOME; install it or set ANDROID_HOME"
  export ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME"
  minix_setup_android_ndk || {
    status=$?
    case "$status" in
      3) die "Android NDK r28 or newer is required; found $ANDROID_NDK_HOME" ;;
      *) die "Android NDK r28 or newer was not found under $ANDROID_HOME/ndk; install it or set ANDROID_NDK_HOME" ;;
    esac
  }
}

prepare_proot_tool_shims() {
  local host_tag readelf awk_bin shim_dir
  case "$(uname -s)-$(uname -m)" in
    Darwin-*) host_tag="darwin-x86_64" ;;
    Linux-x86_64) host_tag="linux-x86_64" ;;
    *) die "unsupported Android NDK host: $(uname -s) $(uname -m)" ;;
  esac

  readelf="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag/bin/llvm-readelf"
  [ -x "$readelf" ] || die "Android NDK llvm-readelf not found: $readelf"
  if command -v gawk >/dev/null 2>&1; then
    awk_bin="$(command -v gawk)"
  elif awk 'BEGIN { exit (strtonum("0x10") == 16 ? 0 : 1) }' >/dev/null 2>&1; then
    awk_bin="$(command -v awk)"
  else
    die "GNU awk is required for PRoot loader metadata; install with: brew install gawk"
  fi

  shim_dir="$REPO_ROOT/build/tool-shims/proot"
  mkdir -p "$shim_dir"
  ln -sf "$readelf" "$shim_dir/readelf"
  ln -sf "$awk_bin" "$shim_dir/awk"
  export PATH="$shim_dir:$PATH"
}

remove_invalid_ios_rootfs_cache() {
  local archive
  for archive in "$REPO_ROOT"/deps/.cache/alpine-minirootfs-*.tar.gz; do
    [ -e "$archive" ] || continue
    tar -tzf "$archive" >/dev/null 2>&1 || rm -f "$archive"
  done
}

prepare_component() {
  case "$1" in
    ios-lame)
      ensure_command xcrun "install Xcode and finish first-launch setup"
      ensure_command make "install Xcode command line tools"
      ;;
    ios-ffmpeg)
      ensure_command xcrun "install Xcode and finish first-launch setup"
      ensure_command make "install Xcode command line tools"
      ensure_command patch "install Xcode command line tools"
      if ! xcrun -sdk iphoneos metal --version >/dev/null 2>&1; then
        die "Xcode Metal Toolchain is missing; run: xcodebuild -downloadComponent MetalToolchain"
      fi
      ;;
    ios-ish)
      ensure_command meson "install with: pip3 install meson"
      ensure_command ninja "install with: brew install ninja"
      ensure_command python3 "install Python 3"
      ensure_lld
      ;;
    ios-rootfs)
      ensure_command meson "install with: pip3 install meson"
      ensure_command ninja "install with: brew install ninja"
      ensure_command curl "install curl"
      ensure_command zip "install zip"
      ;;
    ios-rclone)
      ensure_go_125
      ensure_command xcodebuild "install Xcode and finish first-launch setup"
      ensure_command xcrun "install Xcode and finish first-launch setup"
      ;;
    android-proot)
      ensure_android_native_toolchain
      ensure_command make "install make"
      ensure_command curl "install curl"
      prepare_proot_tool_shims
      ;;
    android-rootfs)
      ensure_command curl "install curl"
      ;;
    android-rclone)
      ensure_android_native_toolchain
      ensure_go_125
      ensure_command gomobile "run: go install golang.org/x/mobile/cmd/gomobile@latest"
      gomobile init
      ;;
  esac
}

build_component() {
  local component="$1"
  prepare_component "$component"
  case "$component" in
    ios-lame)
      rm -rf "$REPO_ROOT/deps/lame-build"
      "$REPO_ROOT/deps/build_lame.sh"
      ;;
    ios-ffmpeg)
      "$REPO_ROOT/deps/build_ffmpeg.sh" clean
      "$REPO_ROOT/deps/build_ffmpeg.sh"
      ;;
    ios-ish)
      "$REPO_ROOT/deps/build_ish.sh" clean
      "$REPO_ROOT/deps/build_ish.sh"
      ;;
    ios-rootfs)
      remove_invalid_ios_rootfs_cache
      if ! "$REPO_ROOT/deps/prepare_alpine_rootfs.sh"; then
        remove_invalid_ios_rootfs_cache
        return 1
      fi
      ;;
    ios-rclone)
      mkdir -p \
        "$REPO_ROOT/deps/build/rclone/device" \
        "$REPO_ROOT/deps/build/rclone/simulator"
      "$REPO_ROOT/deps/build_rclone_ios.sh"
      ;;
    android-proot)
      "$REPO_ROOT/deps/build_proot.sh" clean
      ;;
    android-rootfs)
      rm -f "$REPO_ROOT/src/android/app/src/main/assets/alpine-minirootfs.tar.gz"
      if ! "$REPO_ROOT/scripts/prepare_android_sandbox.sh"; then
        rm -f "$REPO_ROOT/src/android/app/src/main/assets/alpine-minirootfs.tar.gz"
        return 1
      fi
      if ! tar -tzf "$REPO_ROOT/src/android/app/src/main/assets/alpine-minirootfs.tar.gz" >/dev/null 2>&1; then
        rm -f "$REPO_ROOT/src/android/app/src/main/assets/alpine-minirootfs.tar.gz"
        die "Android rootfs download is not a valid gzip tar archive"
      fi
      ;;
    android-rclone)
      "$REPO_ROOT/deps/build_rclone_android.sh"
      mkdir -p "$REPO_ROOT/src/android/app/libs"
      install -m 0644 \
        "$REPO_ROOT/deps/build/rclone/rclone.aar" \
        "$REPO_ROOT/src/android/app/libs/rclone.aar"
      ;;
  esac
}

update_submodules() {
  say "Synchronizing source submodules"
  git -C "$REPO_ROOT" submodule sync --recursive
  case "$PLATFORM" in
    ios) git -C "$REPO_ROOT" submodule update --init --recursive deps/ish ;;
    android) git -C "$REPO_ROOT" submodule update --init --recursive deps/proot ;;
    both) git -C "$REPO_ROOT" submodule update --init --recursive deps/ish deps/proot ;;
  esac
}

case "$PLATFORM" in
  ios) COMPONENTS="ios-lame ios-ffmpeg ios-ish ios-rootfs ios-rclone" ;;
  android) COMPONENTS="android-proot android-rootfs android-rclone" ;;
  both) COMPONENTS="ios-lame ios-ffmpeg ios-ish ios-rootfs ios-rclone android-proot android-rootfs android-rclone" ;;
esac

cd "$REPO_ROOT"
ensure_command git "install Git"
ensure_command shasum "install a SHA-256 utility"
check_registered_builders

if [ "$CHECK_ONLY" -eq 0 ]; then
  mkdir -p "$REPO_ROOT/build"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another dependency reconciliation appears to be running: $LOCK_DIR"
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
  update_submodules
  mkdir -p "$STATE_DIR"
fi

stale_count=0
for component in $COMPONENTS; do
  signature="$(component_signature "$component")"
  if component_is_current "$component" "$signature"; then
    ok "$component"
    continue
  fi

  stale_count=$((stale_count + 1))
  warn "$component: $STALE_REASON"
  [ "$CHECK_ONLY" -eq 1 ] && continue

  say "Building $component"
  build_component "$component"
  outputs_present "$component" || die "$component finished without required output: $MISSING_OUTPUT"
  signature="$(component_signature "$component")"
  tmp_state="$STATE_DIR/$component.sha256.tmp.$$"
  printf '%s\n' "$signature" >"$tmp_state"
  mv "$tmp_state" "$STATE_DIR/$component.sha256"
  ok "$component rebuilt"
done

if [ "$CHECK_ONLY" -eq 1 ] && [ "$stale_count" -gt 0 ]; then
  printf '\n%d dependency component(s) need reconciliation.\n' "$stale_count" >&2
  exit 3
fi

say "Native dependencies are current for $PLATFORM"
