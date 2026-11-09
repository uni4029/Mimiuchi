#!/bin/zsh
# Build Mimiuchi (Release) and install it to ~/Applications.
#
#   Scripts/build.sh            # build + install
#   Scripts/build.sh --no-install
#
# Requirements: Xcode 26+ with the Metal Toolchain
# (xcodebuild -downloadComponent MetalToolchain) and XcodeGen (brew install xcodegen).
# Set MIMIUCHI_NESTED_SANDBOX=1 when building inside another sandbox (e.g. an agent shell),
# which needs SwiftPM/macro sandboxing disabled.
#
# The app is signed with a local certificate (Scripts/setup-signing.sh creates it on the first
# build) so the Accessibility permission for ⌘C+C survives rebuilds. MIMIUCHI_ADHOC_SIGN=1 keeps
# Xcode's ad-hoc signature instead; then the permission must be granted again after every build.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="${DERIVED_DATA:-$PWD/build/DerivedData}"
EXTRA=()
if [[ "${MIMIUCHI_NESTED_SANDBOX:-0}" == "1" ]]; then
  EXTRA=(-IDEPackageSupportDisableManifestSandbox=YES -skipPackagePluginValidation -skipMacroValidation 'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox')
fi
# MLX's C/C++ sources use __FILE__ in error messages. Record their paths relative to the build
# folders so the app binary does not contain this Mac's home directory and folder names.
PREFIX_MAP="OTHER_CFLAGS=\$(inherited) \"-ffile-prefix-map=$DERIVED=/DerivedData\" \"-ffile-prefix-map=$PWD=/Mimiuchi\""

command -v xcodegen >/dev/null && xcodegen generate --quiet
mkdir -p "$DERIVED"
BUILD_LOG="$DERIVED/build.log"
if xcodebuild -project Mimiuchi.xcodeproj -scheme Mimiuchi -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" "${EXTRA[@]}" "$PREFIX_MAP" build >"$BUILD_LOG" 2>&1; then
  tail -3 "$BUILD_LOG"
else
  BUILD_STATUS=$?
  # Package resolution and compiler failures often explain the cause well before the
  # final summary. Keep stdout and stderr together instead of discarding all but 3 lines.
  tail -80 "$BUILD_LOG" >&2
  echo "Build failed. Full log: $BUILD_LOG" >&2
  exit "$BUILD_STATUS"
fi

APP="$DERIVED/Build/Products/Release/Mimiuchi.app"
INSTALLED="$HOME/Applications/Mimiuchi.app"
BUNDLE_ID="local.mimiuchi.Mimiuchi"
designated_requirement() {
  # Ad-hoc signatures only have an implicit requirement, printed as "# designated => cdhash ...".
  # A missing or half-copied app yields an empty string instead of stopping the script.
  codesign -d -r- "$1" 2>/dev/null | sed -n -E 's/^(# )?designated => //p' || true
}

if [[ "${MIMIUCHI_ADHOC_SIGN:-0}" == "1" ]]; then
  echo "Signature: ad-hoc (MIMIUCHI_ADHOC_SIGN=1). Grant the permissions again after each build."
else
  Scripts/sign.sh "$APP"
fi

if [[ "${1:-}" != "--no-install" ]]; then
  # A running Mimiuchi would keep the old build alive (and ask for permissions with it).
  APP_BIN="$INSTALLED/Contents/MacOS/Mimiuchi"
  WAS_RUNNING=0
  if pgrep -f "$APP_BIN" >/dev/null; then
    WAS_RUNNING=1
    echo "Quitting the running Mimiuchi to install the new build..."
    pkill -TERM -f "$APP_BIN" || true
    for _ in {1..40}; do pgrep -f "$APP_BIN" >/dev/null || break; sleep 0.25; done
    pkill -KILL -f "$APP_BIN" 2>/dev/null || true
  fi

  OLD_REQUIREMENT="$(designated_requirement "$INSTALLED")"
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALLED"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed: $INSTALLED"
  if [[ "$OLD_REQUIREMENT" != "$(designated_requirement "$INSTALLED")" ]]; then
    # Permissions granted to another signature stay switched on in System Settings but do not
    # apply to this build, so remove them and let the app ask again.
    if tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 && tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1; then
      echo "New code signature: reset Mimiuchi's Input Monitoring and Accessibility permissions. Allow them again in Mimiuchi (only needed once)."
    else
      echo "New code signature: in System Settings > Privacy & Security, remove Mimiuchi (-) from Input Monitoring and Accessibility, then allow it again from Mimiuchi."
    fi
  fi
  if (( WAS_RUNNING )); then
    open "$INSTALLED"
    echo "Restarted Mimiuchi."
  fi
else
  echo "Built: $APP"
fi
