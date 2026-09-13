#!/bin/bash
# Regenerates Resources/AppIcon.icns. Only needed when the artwork changes; the .icns is
# committed, so build-app.sh just copies it.
# ponytail: drawn from primitives, not SF Symbols -- their licence excludes app icons, and
# primitives need no template tinting. One 1024 draw; sips downsamples the other nine.
set -euo pipefail
cd "$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/draw.swift" <<'SWIFT'
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Rounded-square plate on Apple's icon grid: 824pt of 1024, corner radius 0.2237 of that.
let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                         xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
           ending:   NSColor(srgbRed: 0.11, green: 0.29, blue: 0.82, alpha: 1))?
    .draw(in: plate, angle: -90)

NSColor.white.setFill()

// The drive it all lands on.
NSBezierPath(roundedRect: NSRect(x: 282, y: 212, width: 460, height: 124),
             xRadius: 42, yRadius: 42).fill()

// The arrow into it: head, then stem.
let head = NSBezierPath()
head.move(to: NSPoint(x: 512, y: 372))
head.line(to: NSPoint(x: 362, y: 532))
head.line(to: NSPoint(x: 662, y: 532))
head.close()
head.fill()
NSBezierPath(roundedRect: NSRect(x: 452, y: 512, width: 120, height: 300),
             xRadius: 46, yRadius: 46).fill()

// The drive's status light, punched back out to the plate colour.
NSColor(srgbRed: 0.16, green: 0.40, blue: 0.90, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 652, y: 256, width: 38, height: 38)).fill()

image.unlockFocus()

let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
    .representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swift "$WORK/draw.swift" "$WORK/icon.png"

mkdir -p "$WORK/AppIcon.iconset"
# iconutil demands these exact names; the number before the colon is the pixel size.
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
            512:icon_512x512 1024:icon_512x512@2x; do
    sips -z "${spec%%:*}" "${spec%%:*}" "$WORK/icon.png" \
         --out "$WORK/AppIcon.iconset/${spec##*:}.png" >/dev/null
done

iconutil -c icns "$WORK/AppIcon.iconset" -o AppIcon.icns
echo "wrote Resources/AppIcon.icns"
