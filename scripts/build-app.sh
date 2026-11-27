#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="${DISKGUARD_VERSION:-}"
if [[ -z "$APP_VERSION" && -f "$ROOT_DIR/VERSION" ]]; then
  APP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
fi
APP_VERSION="${APP_VERSION:-1.1.0}"

BUILD_NUMBER="${DISKGUARD_BUILD_NUMBER:-}"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

echo "==> Building release binary (v${APP_VERSION}, build ${BUILD_NUMBER})..."
swift build --disable-sandbox -c release

BIN_PATH="$(swift build --disable-sandbox -c release --show-bin-path)/DiskGuard"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Error: Release binary not found at $BIN_PATH" >&2
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/DiskGuard.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
TMP_ICON_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_ICON_DIR"' EXIT

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "==> Generating DiskGuard app icon..."
swift - "$RESOURCES_DIR/AppIcon.icns" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments[1]

func renderPNG(size: Int) -> Data {
    let fsize = CGFloat(size)
    let rect = CGRect(x: 0, y: 0, width: fsize, height: fsize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx

    let scale = fsize / 1024.0
    ctx.cgContext.scaleBy(x: scale, y: scale)

    let baseRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let insetRect = baseRect.insetBy(dx: 76, dy: 76)
    let bgPath = NSBezierPath(roundedRect: insetRect, xRadius: 205, yRadius: 205)
    bgPath.addClip()

    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.22, alpha: 1.0),
            NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.31, alpha: 1.0)
        ]
    )!
    gradient.draw(in: bgPath, angle: -45)

    NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
    bgPath.lineWidth = 10
    bgPath.stroke()

    let center = CGPoint(x: 512, y: 536)
    let outerRadius: CGFloat = 248
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: outerRadius, startAngle: 140, endAngle: 400, clockwise: false)
    ring.lineWidth = 44
    ring.lineCapStyle = .round
    NSColor(calibratedRed: 0.16, green: 0.80, blue: 0.56, alpha: 0.95).setStroke()
    ring.stroke()

    let amberArc = NSBezierPath()
    amberArc.appendArc(withCenter: center, radius: outerRadius, startAngle: 35, endAngle: 135, clockwise: false)
    amberArc.lineWidth = 44
    amberArc.lineCapStyle = .round
    NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.20, alpha: 0.95).setStroke()
    amberArc.stroke()

    let shield = NSBezierPath()
    let sx: CGFloat = 512
    let sy: CGFloat = 530
    shield.move(to: CGPoint(x: sx, y: sy + 135))
    shield.line(to: CGPoint(x: sx + 108, y: sy + 92))
    shield.curve(
        to: CGPoint(x: sx, y: sy - 135),
        controlPoint1: CGPoint(x: sx + 108, y: sy - 20),
        controlPoint2: CGPoint(x: sx + 60, y: sy - 95)
    )
    shield.curve(
        to: CGPoint(x: sx - 108, y: sy + 92),
        controlPoint1: CGPoint(x: sx - 60, y: sy - 95),
        controlPoint2: CGPoint(x: sx - 108, y: sy - 20)
    )
    shield.close()

    NSColor(calibratedWhite: 1.0, alpha: 0.95).setFill()
    shield.fill()

    let check = NSBezierPath()
    check.move(to: CGPoint(x: sx - 46, y: sy - 2))
    check.line(to: CGPoint(x: sx - 12, y: sy - 38))
    check.line(to: CGPoint(x: sx + 52, y: sy + 36))
    check.lineWidth = 26
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor(calibratedRed: 0.06, green: 0.55, blue: 0.38, alpha: 1.0).setStroke()
    check.stroke()

    NSGraphicsContext.restoreGraphicsState()
    _ = rect
    return rep.representation(using: .png, properties: [:])!
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

let chunks: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("ic11", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024)
]

var body = Data()
for (code, px) in chunks {
    let png = renderPNG(size: px)
    body.append(code.data(using: .ascii)!)
    appendUInt32BE(UInt32(8 + png.count), to: &body)
    body.append(png)
}

var icns = Data()
icns.append("icns".data(using: .ascii)!)
appendUInt32BE(UInt32(8 + body.count), to: &icns)
icns.append(body)

try icns.write(to: URL(fileURLWithPath: outPath))
SWIFT

echo "==> Assembling DiskGuard.app..."
cp "$BIN_PATH" "$MACOS_DIR/DiskGuard"
chmod +x "$MACOS_DIR/DiskGuard"

if [[ -d "$ROOT_DIR/Sources/DiskGuard/Resources/Pets" ]]; then
  cp -R "$ROOT_DIR/Sources/DiskGuard/Resources/Pets" "$RESOURCES_DIR/Pets"
fi

BIN_DIR="$(dirname "$BIN_PATH")"
if [[ -d "$BIN_DIR/DiskGuard_DiskGuard.bundle" ]]; then
  cp -R "$BIN_DIR/DiskGuard_DiskGuard.bundle" "$RESOURCES_DIR/DiskGuard_DiskGuard.bundle"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>DiskGuard</string>
    <key>CFBundleExecutable</key>
    <string>DiskGuard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.diskguard</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DiskGuard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

PREFERRED_IDENTITY="${DISKGUARD_SIGN_IDENTITY:-DiskGuard Local Signing}"
REQUIRE_FIXED_SIGNING="${REQUIRE_FIXED_SIGNING:-0}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$PREFERRED_IDENTITY"; then
  echo "==> Signing DiskGuard.app with fixed identity: $PREFERRED_IDENTITY"
  codesign --force --deep --sign "$PREFERRED_IDENTITY" "$APP_BUNDLE"
elif [[ "$REQUIRE_FIXED_SIGNING" == "1" ]]; then
  echo "Error: Fixed signing identity '$PREFERRED_IDENTITY' not found." >&2
  echo "Run ./scripts/setup-signing-cert.sh first so Full Disk Access persists across updates." >&2
  exit 1
else
  echo "==> Warning: Fixed signing identity '$PREFERRED_IDENTITY' not found; falling back to ad-hoc signing (-)."
  echo "    Run ./scripts/setup-signing-cert.sh once so macOS Full Disk Access persists across updates."
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Done: $APP_BUNDLE (v${APP_VERSION}, build ${BUILD_NUMBER})"
codesign -dv --requirements - "$APP_BUNDLE" 2>&1 || true
