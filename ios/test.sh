#!/bin/sh
# Checks the iPhone app without Xcode, using only the Command Line Tools:
#  1. typechecks the app and the share extension against UIKit/SwiftUI (via the Mac Catalyst SDK)
#  2. builds the network core for macOS and runs it against knockdrop.py on this Mac
#     (real Bonjour and sockets, scripted knocks)
set -e
cd "$(dirname "$0")"
sdk="$(xcrun --show-sdk-path)"
ios="$sdk/System/iOSSupport"
catalyst="-swift-version 5 -sdk $sdk -target arm64-apple-ios17.0-macabi -F $ios/System/Library/Frameworks -I $ios/usr/lib/swift"

echo "typecheck: app"
swiftc -typecheck $catalyst Shared/*.swift App/*.swift
echo "typecheck: share extension"
swiftc -typecheck $catalyst -application-extension Shared/*.swift ShareExtension/*.swift

echo "interop with knockdrop.py"
out="${TMPDIR:-/tmp}/knockdrop-ios-harness"
swiftc -O -swift-version 5 -o "$out" Shared/Core.swift Shared/Conn.swift Shared/Nearby.swift \
  Shared/Claim.swift Shared/OfferServer.swift Shared/Motion.swift Harness/main.swift
"$out" "$(cd .. && pwd)"
