#!/usr/bin/env bash

minix_find_jdk17() {
  local candidate prefix
  for candidate in \
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home; do
    [ -x "$candidate/bin/java" ] && { printf '%s\n' "$candidate"; return; }
  done
  if command -v brew >/dev/null 2>&1; then
    prefix="$(brew --prefix openjdk@17 2>/dev/null || true)"
    candidate="$prefix/libexec/openjdk.jdk/Contents/Home"
    [ -x "$candidate/bin/java" ] && { printf '%s\n' "$candidate"; return; }
  fi
  if [ -x /usr/libexec/java_home ]; then
    candidate="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    [ -x "$candidate/bin/java" ] && { printf '%s\n' "$candidate"; return; }
  fi
  return 1
}

minix_setup_android_toolchain() {
  JAVA_HOME="$(minix_find_jdk17)" || return 1
  : "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  [ -d "$ANDROID_HOME" ] || return 2
  export JAVA_HOME ANDROID_HOME
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
}

minix_find_android_ndk() {
  local candidate base
  for candidate in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
    [ -n "$candidate" ] && [ -d "$candidate" ] && {
      printf '%s\n' "$candidate"
      return
    }
  done

  base="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}/ndk"
  [ -d "$base" ] || return 1
  candidate="$(find "$base" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null |
    sort -V | tail -1)"
  [ -n "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

minix_setup_android_ndk() {
  local revision major
  ANDROID_NDK_HOME="$(minix_find_android_ndk)" || return 1
  revision="$(awk -F= '/^[[:space:]]*Pkg.Revision[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' \
    "$ANDROID_NDK_HOME/source.properties" 2>/dev/null)"
  major="${revision%%.*}"
  case "$major" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "$major" -ge 28 ] || return 3
  export ANDROID_NDK_HOME
  export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
}
