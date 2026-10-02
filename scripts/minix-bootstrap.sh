#!/usr/bin/env bash
# [Minix] Prepare a fresh checkout and produce a Debug build.
#
#   scripts/minix-bootstrap.sh ios|android|both
#   scripts/minix-bootstrap.sh ios|android|both --force-deps
#
# The script never installs Xcode, Android Studio, SDK licenses, or signing
# secrets. It creates missing non-secret templates and fails with the exact
# prerequisite that still needs attention.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/.env"
PLATFORM=""
FORCE_DEPS=0

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/minix-android-toolchain.sh"

usage() {
  sed -n '2,9s/^# \{0,1\}//p' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    ios|android|both)
      [ -z "$PLATFORM" ] || { echo "platform specified more than once" >&2; exit 2; }
      PLATFORM="$1"
      ;;
    --force-deps) FORCE_DEPS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

[ -n "$PLATFORM" ] || { usage; exit 2; }

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

ensure_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command '$1': $2"
}

copy_if_missing() {
  local source="$1" destination="$2"
  [ -f "$destination" ] && return
  [ -f "$source" ] || die "missing template: $source"
  cp "$source" "$destination"
  say "Created ${destination#$REPO_ROOT/}"
}

write_if_missing() {
  local path="$1"
  [ -f "$path" ] && return 1
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  return 0
}

prepare_customization() {
  copy_if_missing \
    "$REPO_ROOT/src/ios/Configs/ProviderCustomization.xcconfig.example" \
    "$REPO_ROOT/src/ios/Configs/ProviderCustomization.xcconfig"
  copy_if_missing \
    "$REPO_ROOT/src/android/app/provider-customization.properties.example" \
    "$REPO_ROOT/src/android/app/provider-customization.properties"
}

prepare_android_signing() {
  if write_if_missing "$ENV_FILE" <<'EOF'
# [Minix] Non-secret pointers to credential files outside the repository.
export MINIX_ASC_ENV="$HOME/.config/minix/asc.env"
export MINIX_ANDROID_ENV="$HOME/.config/minix/android.env"
EOF
  then
    say "Created scripts/.env"
  fi

  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  : "${MINIX_ANDROID_ENV:=$HOME/.config/minix/android.env}"

  if write_if_missing "$MINIX_ANDROID_ENV" <<'EOF'
# [Minix] Persistent Android signing credentials.
export ANDROID_KEYSTORE_FILE=""
export ANDROID_KEYSTORE_PASSWORD=""
export ANDROID_KEY_ALIAS=""
export ANDROID_KEY_PASSWORD=""
EOF
  then
    say "Created Android signing template: $MINIX_ANDROID_ENV"
  fi

  set -a
  # shellcheck disable=SC1090
  source "$MINIX_ANDROID_ENV"
  set +a

  local missing=""
  [ -n "${ANDROID_KEYSTORE_FILE:-}" ] || missing="$missing ANDROID_KEYSTORE_FILE"
  [ -n "${ANDROID_KEYSTORE_PASSWORD:-}" ] || missing="$missing ANDROID_KEYSTORE_PASSWORD"
  [ -n "${ANDROID_KEY_ALIAS:-}" ] || missing="$missing ANDROID_KEY_ALIAS"
  [ -n "${ANDROID_KEY_PASSWORD:-}" ] || missing="$missing ANDROID_KEY_PASSWORD"
  [ -z "$missing" ] || die "fill the shared Android signing values in $MINIX_ANDROID_ENV:$missing"
  [ -f "$ANDROID_KEYSTORE_FILE" ] || die "Android keystore not found: $ANDROID_KEYSTORE_FILE"
}

preflight_ios() {
  ensure_command xcodebuild "install Xcode and finish first-launch setup"
  ensure_command xcrun "install Xcode and finish first-launch setup"
  ensure_command meson "install with: pip3 install meson"
  ensure_command ninja "install with: brew install ninja"
  ensure_command go "install Go 1.25 or newer"
}

preflight_android() {
  local status
  minix_setup_android_toolchain || {
    status=$?
    case "$status" in
      1) die "JDK 17 not found; install it with: brew install openjdk@17" ;;
      2) die "Android SDK not found; install it with Android Studio or set ANDROID_HOME" ;;
      *) die "Android toolchain setup failed" ;;
    esac
  }
  minix_setup_android_ndk || {
    status=$?
    case "$status" in
      3) die "Android NDK r28 or newer is required; found $ANDROID_NDK_HOME" ;;
      *) die "Android NDK r28 or newer not found; install it with Android Studio or set ANDROID_NDK_HOME" ;;
    esac
  }
  [ -d "$ANDROID_HOME/platforms/android-36" ] ||
    die "Android SDK Platform 36 is missing; install it with Android Studio"
  ensure_command go "install Go 1.25 or newer"
  ensure_command gomobile "run: go install golang.org/x/mobile/cmd/gomobile@latest"
  prepare_android_signing
}

cd "$REPO_ROOT"
ensure_command git "install Git"
ensure_command rg "install with: brew install ripgrep"
prepare_customization

case "$PLATFORM" in
  ios) preflight_ios ;;
  android) preflight_android ;;
  both)
    preflight_ios
    preflight_android
    ;;
esac

say "Initializing submodules"
git submodule sync --recursive
case "$PLATFORM" in
  ios) git submodule update --init --recursive deps/ish ;;
  android) git submodule update --init --recursive deps/proot ;;
  both) git submodule update --init --recursive deps/ish deps/proot ;;
esac

say "Checking Minix invariants"
"$REPO_ROOT/scripts/minix-check-invariants.sh"

deps_args=("$PLATFORM")
[ "$FORCE_DEPS" -eq 1 ] && deps_args+=(--force)
"$REPO_ROOT/scripts/minix-deps.sh" "${deps_args[@]}"

case "$PLATFORM" in
  ios) "$REPO_ROOT/scripts/minix-debug.sh" ios ;;
  android) "$REPO_ROOT/scripts/minix-debug.sh" android ;;
  both)
    "$REPO_ROOT/scripts/minix-debug.sh" ios
    "$REPO_ROOT/scripts/minix-debug.sh" android
    ;;
esac

say "Bootstrap complete for $PLATFORM"
