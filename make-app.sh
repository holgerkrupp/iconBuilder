#!/bin/bash
# Build IconBuilder.app and drop it in the project directory, ready to run.
#
# The app is a plain Xcode target now (there is no Swift package), so this is a
# thin wrapper around xcodebuild for people who'd rather not open Xcode.
# Usage: ./make-app.sh [--release] [--no-paywall]
#
# --no-paywall builds with Pro unlocked (compiles in the NO_PAYWALL flag). It is
# for local testing only — never ship a build made with it.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=Debug
NO_PAYWALL=0
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=Release ;;
        --no-paywall) NO_PAYWALL=1 ;;
        *) echo "Unknown option: $arg" >&2
           echo "Usage: ./make-app.sh [--release] [--no-paywall]" >&2
           exit 1 ;;
    esac
done

# Overriding this setting on the command line replaces the target's value
# rather than extending it, so DEBUG has to be carried over explicitly.
CONDITIONS=""
[ "$CONFIG" = Debug ] && CONDITIONS="DEBUG"
if [ "$NO_PAYWALL" = 1 ]; then
    CONDITIONS="${CONDITIONS:+$CONDITIONS }NO_PAYWALL"
    echo "*** Paywall disabled — testing build, do not distribute. ***"
fi

echo "Building ($CONFIG)…"
DERIVED="$(mktemp -d)"
trap 'rm -rf "$DERIVED"' EXIT

xcodebuild \
    -project IconBuilder.xcodeproj \
    -scheme IconBuilder \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" \
    build >/dev/null

APP="IconBuilder.app"
rm -rf "$APP"
cp -R "$DERIVED/Build/Products/$CONFIG/$APP" "$APP"

# Deliberately no re-signing here. Xcode already signed the app with its
# entitlements; an ad-hoc `codesign --force --deep --sign -` would strip the
# app sandbox, so this copy would behave differently from the shipping one
# (Application Support would land outside the container, for instance).

echo "Built $APP"
echo "Run:  open $APP"
echo "Or:   open -a \$PWD/$APP /path/to/YourIcon.icon"
