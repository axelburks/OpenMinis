#!/usr/bin/env bash
# [Minix] Reproducible Debug build and device install.
#
#   scripts/minix-debug.sh android [--install] [--device SERIAL]
#   scripts/minix-debug.sh ios
#   scripts/minix-debug.sh ios --install --device UDID

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$REPO_ROOT/src/android"
IOS_PROJECT="$REPO_ROOT/src/ios/Minis.xcodeproj"
BUILD_OUT="$REPO_ROOT/build/debug"
ENV_FILE="$REPO_ROOT/scripts/.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/minix-android-toolchain.sh"

PLATFORM=""
DO_INSTALL=0
DEVICE=""

usage() {
  sed -n '2,7s/^# \{0,1\}//p' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    android|ios) PLATFORM="$1" ;;
    --install) DO_INSTALL=1 ;;
    --device)
      shift
      [ "$#" -gt 0 ] || { echo "--device requires an identifier" >&2; exit 2; }
      DEVICE="$1"
      ;;
    --device=*) DEVICE="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

[ -n "$PLATFORM" ] || { usage; exit 2; }

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

load_android_signing() {
  [ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  : "${MINIX_ANDROID_ENV:=$HOME/.config/minix/android.env}"
  [ -f "$MINIX_ANDROID_ENV" ] || die "missing Android signing env: $MINIX_ANDROID_ENV"
  set -a
  # shellcheck disable=SC1090
  source "$MINIX_ANDROID_ENV"
  set +a

  local missing=()
  [ -n "${ANDROID_KEYSTORE_FILE:-}" ] || missing+=("ANDROID_KEYSTORE_FILE")
  [ -n "${ANDROID_KEYSTORE_PASSWORD:-}" ] || missing+=("ANDROID_KEYSTORE_PASSWORD")
  [ -n "${ANDROID_KEY_ALIAS:-}" ] || missing+=("ANDROID_KEY_ALIAS")
  [ -n "${ANDROID_KEY_PASSWORD:-}" ] || missing+=("ANDROID_KEY_PASSWORD")
  [ "${#missing[@]}" -eq 0 ] || die "Android signing not set: ${missing[*]}"
  [ -f "$ANDROID_KEYSTORE_FILE" ] || die "keystore not found: $ANDROID_KEYSTORE_FILE"
}

tap_xml_bounds_center() {
  local adb="$1" device="$2" line="$3"
  local coords x1 y1 x2 y2
  coords="$(printf '%s\n' "$line" | sed -n \
    -e 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' \
    -e 's/^\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]$/\1 \2 \3 \4/p')"
  [ -n "$coords" ] || return 1
  read -r x1 y1 x2 y2 <<EOF
$coords
EOF
  "$adb" -s "$device" shell input tap "$(((x1 + x2) / 2))" "$(((y1 + y2) / 2))"
}

approve_android_install_if_present() {
  local adb="$1" device="$2" focus focus_lower xml_file has_target checkbox button
  focus="$("$adb" -s "$device" shell dumpsys window 2>/dev/null | grep 'mCurrentFocus' | head -1 || true)"
  focus_lower="$(printf '%s' "$focus" | tr '[:upper:]' '[:lower:]')"
  case "$focus_lower" in
    *packageinstaller*|*permissioncontroller*|*securitycenter*|*safecenter*) ;;
    *) return 1 ;;
  esac
  case "$focus_lower" in
    *permissioninfo*)
      "$adb" -s "$device" shell input keyevent 4
      return 1
      ;;
  esac

  command -v xmllint >/dev/null 2>&1 || return 1
  "$adb" -s "$device" shell uiautomator dump /sdcard/minix-install.xml >/dev/null 2>&1 || return 1
  xml_file="$(mktemp -t minix-install-ui)"
  "$adb" -s "$device" exec-out cat /sdcard/minix-install.xml >"$xml_file" 2>/dev/null || {
    rm -f "$xml_file"
    return 1
  }
  has_target="$(xmllint --xpath 'boolean(//node[@text="Minix" or @content-desc="Minix"])' "$xml_file" 2>/dev/null || true)"
  [ "$has_target" = "true" ] || {
    rm -f "$xml_file"
    return 1
  }

  checkbox="$(xmllint --xpath 'string((//node[@checkable="true" and @checked="false" and (contains(@resource-id,"risk") or contains(@resource-id,"agree") or contains(@text,"了解") or contains(@text,"同意") or contains(@text,"understand") or contains(@text,"agree"))])[1]/@bounds)' "$xml_file" 2>/dev/null || true)"
  if [ -n "$checkbox" ]; then
    tap_xml_bounds_center "$adb" "$device" "$checkbox"
    sleep 1
  fi

  button="$(xmllint --xpath 'string((//node[@clickable="true" and @enabled="true" and (@resource-id="android:id/button1" or ((contains(substring-after(@resource-id,":id/"),"install") or contains(substring-after(@resource-id,":id/"),"continue")) and not(contains(substring-after(@resource-id,":id/"),"cancel"))) or @text="安装" or @text="继续安装" or @text="Install" or @text="Continue" or @content-desc="安装" or @content-desc="继续安装" or @content-desc="Install" or @content-desc="Continue")])[1]/@bounds)' "$xml_file" 2>/dev/null || true)"
  rm -f "$xml_file"
  [ -n "$button" ] || return 1
  tap_xml_bounds_center "$adb" "$device" "$button"
}

android_debug() {
  load_android_signing
  minix_setup_android_toolchain || die "JDK 17 or Android SDK not found"

  mkdir -p "$BUILD_OUT"
  say "Android Debug build"
  (cd "$ANDROID_DIR" && ./gradlew :app:assembleDebug --no-daemon)

  local src_apk="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
  local dest_apk="$BUILD_OUT/Minix-debug.apk"
  [ -f "$src_apk" ] || die "debug APK not produced: $src_apk"
  cp -f "$src_apk" "$dest_apk"
  say "APK ready: $dest_apk"

  local apksigner
  apksigner="$(ls -t "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | head -1)"
  if [ -n "$apksigner" ]; then
    "$apksigner" verify --print-certs "$dest_apk" 2>/dev/null \
      | grep -E 'certificate DN|certificate SHA-256 digest' \
      | head -2 || true
  fi

  if [ "$DO_INSTALL" -eq 0 ]; then
    return 0
  fi
  local adb="$ANDROID_HOME/platform-tools/adb"
  [ -x "$adb" ] || die "adb not found: $adb"

  if [ -z "$DEVICE" ]; then
    local count
    count="$("$adb" devices | awk '$2 == "device" { n++ } END { print n + 0 }')"
    [ "$count" -eq 1 ] || die "expected one Android device, found $count; pass --device SERIAL"
    DEVICE="$("$adb" devices | awk '$2 == "device" { print $1; exit }')"
  fi

  say "Install on $DEVICE"
  local install_log install_pid install_status deadline install_output approval_attempts
  install_log="$(mktemp -t minix-adb-install)"
  "$adb" -s "$DEVICE" install -r "$dest_apk" >"$install_log" 2>&1 &
  install_pid=$!
  deadline=$((SECONDS + 120))
  approval_attempts=0
  while kill -0 "$install_pid" 2>/dev/null; do
    if [ "$approval_attempts" -lt 3 ] &&
       approve_android_install_if_present "$adb" "$DEVICE"; then
      approval_attempts=$((approval_attempts + 1))
      say "Confirmed Minix installation in the system package installer"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$install_pid" 2>/dev/null || true
      wait "$install_pid" 2>/dev/null || true
      install_output="$(cat "$install_log")"
      rm -f "$install_log"
      [ -n "$install_output" ] && printf '%s\n' "$install_output" >&2
      die "timed out waiting for the system package installer"
    fi
    sleep 1
  done
  if wait "$install_pid"; then
    install_status=0
  else
    install_status=$?
  fi
  install_output="$(cat "$install_log")"
  rm -f "$install_log"
  if [ "$install_status" -ne 0 ]; then
    printf '%s\n' "$install_output" >&2
    if printf '%s' "$install_output" | grep -q 'INSTALL_FAILED_UPDATE_INCOMPATIBLE'; then
      die "existing Minix uses an old certificate; request approval before the one-time uninstall: adb -s $DEVICE uninstall com.axel.minix"
    fi
    if printf '%s' "$install_output" | grep -Eq 'INSTALL_FAILED_USER_RESTRICTED|INSTALL_CANCELED_BY_USER'; then
      die "the system package installer rejected the request"
    fi
    die "adb install failed"
  fi
  printf '%s\n' "$install_output"
  "$adb" -s "$DEVICE" shell monkey \
    -p com.axel.minix \
    -c android.intent.category.LAUNCHER \
    1 >/dev/null
  say "Minix Debug installed and launched on $DEVICE"
}

ios_debug() {
  command -v xcodebuild >/dev/null || die "xcodebuild not found"
  if [ "$DO_INSTALL" -eq 0 ]; then
    say "iOS Debug build"
    xcodebuild \
      -quiet \
      -project "$IOS_PROJECT" \
      -scheme Minis \
      -configuration Debug \
      -destination 'generic/platform=iOS' \
      CODE_SIGNING_ALLOWED=NO \
      build
    return
  fi

  [ -n "$DEVICE" ] || die "iOS install requires --device UDID"
  say "iOS Debug build for $DEVICE"
  xcodebuild \
    -quiet \
    -project "$IOS_PROJECT" \
    -scheme Minis \
    -configuration Debug \
    -destination "id=$DEVICE" \
    -allowProvisioningUpdates \
    build

  local settings target_dir wrapper app_path
  settings="$(xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme Minis \
    -configuration Debug \
    -destination "id=$DEVICE" \
    -showBuildSettings)"
  target_dir="$(printf '%s\n' "$settings" | awk -F' = ' '/ TARGET_BUILD_DIR =/{print $2; exit}')"
  wrapper="$(printf '%s\n' "$settings" | awk -F' = ' '/ WRAPPER_NAME =/{print $2; exit}')"
  app_path="$target_dir/$wrapper"
  [ -d "$app_path" ] || die "built app not found: $app_path"

  xcrun devicectl device install app --device "$DEVICE" "$app_path"
  xcrun devicectl device process launch \
    --device "$DEVICE" \
    --terminate-existing \
    com.axel.minix
  say "Minix Debug installed and launched on $DEVICE"
}

case "$PLATFORM" in
  android) android_debug ;;
  ios) ios_debug ;;
esac
