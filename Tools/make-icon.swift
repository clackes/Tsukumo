// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only
// Generates the minimal icon: graphite rounded square, a light ring with a dot.
// Usage: swift Tools/make-icon.swift <.iconset folder>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
  let s = CGFloat(px)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext
  // Standard macOS margin: the body takes up 82% of the canvas.
  let body = CGRect(x: s * 0.09, y: s * 0.09, width: s * 0.82, height: s * 0.82)
  let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
  ctx.addPath(path); ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState(); ctx.addPath(path); ctx.clip()
  let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(white: 0.20, alpha: 1).cgColor, NSColor(white: 0.07, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: s / 2, y: body.maxY), end: CGPoint(x: s / 2, y: body.minY), options: [])
  ctx.restoreGState()
  // Ring and dot.
  let center = CGPoint(x: s / 2, y: s / 2)
  let radius = body.width * 0.27
  ctx.setStrokeColor(NSColor(white: 0.96, alpha: 1).cgColor)
  ctx.setLineWidth(body.width * 0.075)
  ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
  ctx.strokePath()
  let dot = body.width * 0.085
  ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
  ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
  ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
  ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes { try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png")) }
