#!/usr/bin/env bash
# [Minix] Run platform tests with the required local toolchain.
#
#   scripts/minix-test.sh android
#   scripts/minix-test.sh android --tests CLASS_NAME
#   scripts/minix-test.sh ios --device UDID
#   scripts/minix-test.sh ios --device UDID --only-testing MinisTests/SuiteName

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$REPO_ROOT/src/android"
IOS_PROJECT="$REPO_ROOT/src/ios/Minis.xcodeproj"
ENV_FILE="$REPO_ROOT/scripts/.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/minix-android-toolchain.sh"

PLATFORM=""
DEVICE=""
ANDROID_TEST=""
IOS_TEST=""

usage() {
  sed -n '2,7s/^# \{0,1\}//p' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    android|ios) PLATFORM="$1" ;;
    --device)
      shift
      [ "$#" -gt 0 ] || { echo "--device requires an identifier" >&2; exit 2; }
      DEVICE="$1"
      ;;
    --device=*) DEVICE="${1#*=}" ;;
    --tests)
      shift
      [ "$#" -gt 0 ] || { echo "--tests requires a class name" >&2; exit 2; }
      ANDROID_TEST="$1"
      ;;
    --tests=*) ANDROID_TEST="${1#*=}" ;;
    --only-testing)
      shift
      [ "$#" -gt 0 ] || { echo "--only-testing requires a test identifier" >&2; exit 2; }
      IOS_TEST="$1"
      ;;
    --only-testing=*) IOS_TEST="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

[ -n "$PLATFORM" ] || { usage; exit 2; }

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

case "$PLATFORM" in
  android)
    minix_setup_android_toolchain || {
      echo "JDK 17 or Android SDK not found" >&2
      exit 1
    }
    args=(:app:testDebugUnitTest --no-daemon)
    if [ -n "$ANDROID_TEST" ]; then
      args+=(--tests "$ANDROID_TEST")
    fi
    (cd "$ANDROID_DIR" && ./gradlew "${args[@]}")
    ;;
  ios)
    DEVICE="${DEVICE:-${MINIX_IOS_TEST_DEVICE:-}}"
    [ -n "$DEVICE" ] || {
      echo "iOS tests require --device UDID or MINIX_IOS_TEST_DEVICE" >&2
      exit 1
    }
    args=(
      -quiet
      -project "$IOS_PROJECT"
      -scheme Minis
      -destination "id=$DEVICE"
      -parallel-testing-enabled NO
    )
    if [ -n "$IOS_TEST" ]; then
      args+=("-only-testing:$IOS_TEST")
    fi
    xcodebuild "${args[@]}" test
    ;;
esac
