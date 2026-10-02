#!/usr/bin/env bash
# [Minix] Release helper: build+upload iOS to TestFlight, build a signed Android
# release APK, and (separately) promote a tested iOS build to the external group.
# Run after you've finished dev/debugging.
#
#   scripts/minix-release.sh                   # build both
#   scripts/minix-release.sh ios               # iOS: archive → export → upload
#   scripts/minix-release.sh android           # Android: signed release APK
#   scripts/minix-release.sh --no-upload ios   # iOS: archive + export IPA locally only
#   scripts/minix-release.sh promote-ios       # AFTER you've tested: assign latest
#                                              #   build to the EXTERNAL group + submit
#                                              #   for beta review (public release)
#
# The flow is two steps on purpose:
#   (1) `minix-release.sh ios` uploads a build to TestFlight.
#   (2) once happy, `minix-release.sh promote-ios` submits for beta review and releases
#       to the EXTERNAL group — that's the public release.
#
# iOS uses the `asc` CLI (https://github.com/rork/asc); the script installs it
# via Homebrew if missing. Credentials come from environment variables
# (ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_PATH) — no keychain, no prompts.
#
# Android signing comes from env vars (ANDROID_KEYSTORE_FILE/…_PASSWORD/KEY_ALIAS/
# KEY_PASSWORD). The same persistent certificate signs Debug, Perf, and Release;
# without it a release build fails fast instead of using a machine-local key.
#
# Secret env files live OUTSIDE the repo; scripts/.env (gitignored)
# only stores their paths. The script bootstraps everything on first run: it
# creates scripts/.env and the pointed-at asc.env / android.env as commented
# templates when absent, and reports exactly which variables still need values.
# External group name defaults to External (override via ASC_EXTERNAL_GROUP).
#
# Native deps must already be built (see AGENTS.md §3 / BUILDING.md).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$REPO_ROOT/src/ios"
ANDROID_DIR="$REPO_ROOT/src/android"
BUILD_OUT="$REPO_ROOT/build/release"
IOS_BUNDLE_ID="com.axel.minix"
IOS_SCHEME="Minis"
IOS_PROJECT="$IOS_DIR/Minis.xcodeproj"
ASC_EXTERNAL_GROUP="External"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/minix-android-toolchain.sh"

PLATFORM="both"
DO_UPLOAD=1
for arg in "$@"; do
  case "$arg" in
    ios|android|both|promote-ios) PLATFORM="$arg" ;;
    --no-upload) DO_UPLOAD=0 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$BUILD_OUT"

# Secrets live OUTSIDE the repo and are never committed. The
# only thing tracked here is scripts/.env — a gitignored pointer file that holds
# paths to those secret env files plus any non-secret overrides. Layout:
#
#   scripts/.env                              (gitignored pointer)
#     MINIX_ASC_ENV=/path/to/asc.env          → iOS: ASC_KEY_ID/ISSUER_ID/PRIVATE_KEY_PATH
#     MINIX_ANDROID_ENV=/path/to/android.env  → Android: ANDROID_KEYSTORE_FILE/…_PASSWORD/KEY_ALIAS/KEY_PASSWORD
#     ASC_EXTERNAL_GROUP                      (optional external group-name override)
#
# All of these are auto-created as commented templates on first run; nothing to
# copy by hand.
ENV_FILE="$REPO_ROOT/scripts/.env"

# write_if_absent PATH  <<'EOF' … EOF   — create a file with template content,
# only when it doesn't already exist (never clobbers real secrets).
write_if_absent() {
  local path="$1"
  [ -f "$path" ] && return 1
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  return 0
}

# Create scripts/.env as a commented template pointing at default secret-file
# locations under ~/.config/minix. The user edits the paths (or the files those
# paths point at) — both get bootstrapped below.
if write_if_absent "$ENV_FILE" <<'EOF'
# [Minix] minix-release.sh pointer file (gitignored). NOTHING secret lives here — only
# paths to out-of-repo secret env files, plus optional non-secret overrides.

# iOS — shell file exporting ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_PATH.
export MINIX_ASC_ENV="$HOME/.config/minix/asc.env"

# Android — shell file exporting the persistent Minix signing vars.
export MINIX_ANDROID_ENV="$HOME/.config/minix/android.env"

# Optional: external TestFlight group name (default: External).
# export ASC_EXTERNAL_GROUP="External"
EOF
then
  say "created $ENV_FILE (edit the paths if you keep secrets elsewhere)"
fi

# We `set -a` so anything sourced is exported to child processes (asc, gradle).
set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

# Bootstrap the pointed-at secret files as commented templates when missing, so
# the user just fills in values. Real files are never overwritten.
: "${MINIX_ASC_ENV:=$HOME/.config/minix/asc.env}"
: "${MINIX_ANDROID_ENV:=$HOME/.config/minix/android.env}"

if write_if_absent "$MINIX_ASC_ENV" <<'EOF'
# [Minix] iOS App Store Connect credentials for asc (out-of-repo secret file).
# Fill in the three values, then re-run scripts/minix-release.sh.
export ASC_KEY_ID=""            # 10-char key id, e.g. ABCDE12345
export ASC_ISSUER_ID=""         # issuer uuid, e.g. 12345678-abcd-...
export ASC_PRIVATE_KEY_PATH=""  # path to AuthKey_XXXXXXXXXX.p8
EOF
then
  say "created iOS credentials template: $MINIX_ASC_ENV"
fi

if write_if_absent "$MINIX_ANDROID_ENV" <<'EOF'
# [Minix] Persistent Android signing credentials (out-of-repo secret file).
# Fill in the four values, then re-run scripts/minix-release.sh android.
export ANDROID_KEYSTORE_FILE=""      # path to minix-release.jks
export ANDROID_KEYSTORE_PASSWORD=""
export ANDROID_KEY_ALIAS=""          # e.g. minix
export ANDROID_KEY_PASSWORD=""
EOF
then
  say "created Android signing template: $MINIX_ANDROID_ENV"
fi

# Re-source now that the pointed-at files exist (first run just created them).
set -a
[ -f "$MINIX_ASC_ENV" ] && source "$MINIX_ASC_ENV"
[ -f "$MINIX_ANDROID_ENV" ] && source "$MINIX_ANDROID_ENV"
set +a

# Minimal JSON string extractor (avoids a jq dependency). Given `--field key`,
# prints the first "key":"value" string value from stdin. Good enough for the
# flat id/version fields we read out of `asc ... --output json`.
json_str() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }

# --- shared asc helpers ----------------------------------------------------
# Auth is env-based (ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_PATH sourced
# from the out-of-repo asc.env). This avoids the macOS keychain entirely — no
# prompts, and it works from any shell context.

# Install the asc CLI via Homebrew when it's missing.
ensure_asc() {
  command -v asc >/dev/null && return 0
  command -v brew >/dev/null || die "asc CLI not found and Homebrew unavailable — install asc from https://github.com/rork/asc"
  say "asc CLI not found — installing via Homebrew…"
  brew install asc || die "brew install asc failed"
}

asc_ready() {
  ensure_asc
  local missing=()
  [ -n "${ASC_KEY_ID:-}" ]          || missing+=("ASC_KEY_ID")
  [ -n "${ASC_ISSUER_ID:-}" ]       || missing+=("ASC_ISSUER_ID")
  [ -n "${ASC_PRIVATE_KEY_PATH:-}" ] || missing+=("ASC_PRIVATE_KEY_PATH")
  if [ "${#missing[@]}" -gt 0 ]; then
    die "iOS credentials not set: ${missing[*]}. Fill them in: $MINIX_ASC_ENV"
  fi
  [ -f "$ASC_PRIVATE_KEY_PATH" ] || die "ASC_PRIVATE_KEY_PATH file not found: $ASC_PRIVATE_KEY_PATH (fix in $MINIX_ASC_ENV)"
}

asc_app_id() {
  local id
  id="$(asc apps list --bundle-id "$IOS_BUNDLE_ID" --output json 2>/dev/null | json_str id)"
  [ -n "$id" ] || die "no App Store Connect app for bundle id $IOS_BUNDLE_ID (create it first)"
  echo "$id"
}

asc_group_id() {
  local app_id="$1" name="$2" gid
  gid="$(asc testflight groups list --app "$app_id" --output json 2>/dev/null \
        | awk -v n="\"name\":\"$name\"" 'BEGIN{RS="}"} $0 ~ n {print}' \
        | json_str id)"
  [ -n "$gid" ] || die "TestFlight group '$name' not found for this app — create it first"
  echo "$gid"
}

ios_marketing_version() {
  xcodebuild -showBuildSettings -project "$IOS_PROJECT" -scheme "$IOS_SCHEME" \
    -configuration Release 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION =/{print $2; exit}'
}

# ---------------------------------------------------------------------------
release_ios() {
  say "iOS: TestFlight release"
  command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"
  ensure_asc  # asc xcode archive/export is used even for local-only IPA export

  local mkt; mkt="$(ios_marketing_version)"
  [ -n "$mkt" ] || die "could not read MARKETING_VERSION"
  say "iOS marketing version: $mkt"

  # Effective upload = requested AND iOS credentials present (env-based). Without
  # them we still build + export a local IPA, but never touch App Store Connect.
  local do_upload=0
  if [ "$DO_UPLOAD" = 1 ]; then
    if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && \
       [ -n "${ASC_PRIVATE_KEY_PATH:-}" ]; then
      ensure_asc
      do_upload=1
    else
      warn "iOS credentials not set — building a local IPA only (no upload)."
      warn "  fill in ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_PATH: $MINIX_ASC_ENV"
    fi
  fi

  # Build number: for a real upload, ask ASC for the next one (clean 1,2,3…);
  # fails hard if unreachable so we never fabricate a number. Local-only export
  # just reuses the project's own value (it's never uploaded).
  local app_id="" build_num
  if [ "$do_upload" = 1 ]; then
    app_id="$(asc_app_id)"
    build_num="$(asc builds next-build-number --app "$app_id" --version "$mkt" \
                 --platform IOS --output json 2>/dev/null | json_str nextBuildNumber)"
    [ -n "$build_num" ] || die "could not get next build number from App Store Connect"
  else
    build_num="$(xcodebuild -showBuildSettings -project "$IOS_PROJECT" -scheme "$IOS_SCHEME" \
                 -configuration Release 2>/dev/null \
                 | awk -F' = ' '/ CURRENT_PROJECT_VERSION =/{print $2; exit}')"
    build_num="${build_num:-1}"
  fi
  say "iOS build number: $build_num"

  # Archive. Override version+build across ALL targets (app + extensions) so
  # Apple's embedded-extension version check passes despite the pbxproj mismatch.
  local archive="$BUILD_OUT/Minix-$mkt-$build_num.xcarchive"
  say "archiving → $archive"
  asc xcode archive \
    --project "$IOS_PROJECT" --scheme "$IOS_SCHEME" \
    --archive-path "$archive" --overwrite \
    --xcodebuild-flag=-configuration --xcodebuild-flag=Release \
    --xcodebuild-flag="MARKETING_VERSION=$mkt" \
    --xcodebuild-flag="CURRENT_PROJECT_VERSION=$build_num" \
    --xcodebuild-flag=-allowProvisioningUpdates

  local ipa="$BUILD_OUT/Minix-$mkt-$build_num.ipa"
  say "exporting IPA → $ipa"
  asc xcode export --archive-path "$archive" --ipa-path "$ipa" --overwrite \
    --xcodebuild-flag=-allowProvisioningUpdates

  if [ "$do_upload" != 1 ]; then
    say "iOS done: local IPA at $ipa (upload skipped)."
    return
  fi

  say "uploading to App Store Connect…"
  asc builds upload --app "$app_id" --ipa "$ipa"

  say "waiting for build $mkt($build_num) to finish processing…"
  asc builds wait --app "$app_id" --latest

  say "iOS done: build $mkt($build_num) uploaded to TestFlight."
  say "  When happy, release publicly:"
  say "    scripts/minix-release.sh promote-ios"
}

# ---------------------------------------------------------------------------
# Separate, explicit step: only once you've tested the uploaded build. Assigns
# the latest build to the EXTERNAL group and submits it for beta review (both in
# one asc call via --submit). That's the public release.
promote_ios() {
  say "iOS: promote latest build to external group '$ASC_EXTERNAL_GROUP'"
  asc_ready
  local app_id; app_id="$(asc_app_id)"
  local egid; egid="$(asc_group_id "$app_id" "$ASC_EXTERNAL_GROUP")"
  asc builds add-groups --app "$app_id" --latest --group "$egid" --submit --confirm
  say "iOS promote done: latest build submitted for beta review + external group."
  say "  Testers get it once Apple's beta review passes (usually a few hours)."
}

# ---------------------------------------------------------------------------
release_android() {
  say "Android: signed release APK"
  # Release signing must use the same persistent certificate as official
  # Debug/Perf builds. Never fall back to a machine-local debug key.
  local missing=()
  [ -n "${ANDROID_KEYSTORE_FILE:-}" ]     || missing+=("ANDROID_KEYSTORE_FILE")
  [ -n "${ANDROID_KEYSTORE_PASSWORD:-}" ] || missing+=("ANDROID_KEYSTORE_PASSWORD")
  [ -n "${ANDROID_KEY_ALIAS:-}" ]         || missing+=("ANDROID_KEY_ALIAS")
  [ -n "${ANDROID_KEY_PASSWORD:-}" ]      || missing+=("ANDROID_KEY_PASSWORD")
  if [ "${#missing[@]}" -gt 0 ]; then
    die "Android signing not set: ${missing[*]}. Fill them in: $MINIX_ANDROID_ENV"
  fi
  [ -f "$ANDROID_KEYSTORE_FILE" ] || die "ANDROID_KEYSTORE_FILE not found: $ANDROID_KEYSTORE_FILE (fix in $MINIX_ANDROID_ENV)"

  minix_setup_android_toolchain || die "JDK 17 or Android SDK not found"
  # NDK is resolved by AGP under $ANDROID_HOME/ndk/<version> automatically; we
  # deliberately don't pin ANDROID_NDK_HOME here so it can't drift from the AGP
  # default. If the matching NDK isn't installed the Gradle error says which.

  # --no-daemon: a long-lived Gradle daemon that was started with a different
  # (or broken) environment poisons child-process spawning — aapt2/ninja fail
  # with "Daemon startup failed" / "problem starting process 'ninja'" even
  # though the binaries run fine standalone. A fresh JVM per release run is
  # cheap insurance for a script that runs occasionally.
  ( cd "$ANDROID_DIR" && ./gradlew :app:assembleRelease --no-daemon )

  local apk="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
  [ -f "$apk" ] || die "release APK not produced"
  local dest="$BUILD_OUT/Minix-release.apk"
  cp -f "$apk" "$dest"
  say "Android done: $dest"
  # Report the signing subject (pick whichever build-tools has apksigner).
  local apksigner
  apksigner="$(ls -t "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | head -1)"
  if [ -n "$apksigner" ]; then
    "$apksigner" verify --print-certs "$dest" 2>/dev/null \
      | grep -i "certificate DN" | head -1 || true
  fi
}

# ---------------------------------------------------------------------------
case "$PLATFORM" in
  ios) release_ios ;;
  android) release_android ;;
  both) release_ios; release_android ;;
  promote-ios) promote_ios ;;
esac

say "All requested releases complete. Artifacts in $BUILD_OUT/"
