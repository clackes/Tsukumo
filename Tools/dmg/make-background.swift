// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only
// Draws the DMG window background: an arrow from the app to the
// Applications folder and a line of instructions. Mid tone, so the icon
// labels read both with a light Finder (black text) and a dark one (white text).
// Usage: swift Tools/dmg/make-background.swift <output folder>
// Writes background.png (1x) and background@2x.png; make-dmg.sh merges them into a TIFF.
import AppKit

/// The same measures used by make-dmg.sh for window and icons.
let size = CGSize(width: 660, height: 420)
let appCenter = CGPoint(x: 175, y: 200)
let applicationsCenter = CGPoint(x: 485, y: 200)

let out = CommandLine.arguments.dropFirst().first ?? "."
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(scale: CGFloat) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext
  let bounds = CGRect(origin: .zero, size: size)
  // Finder coordinates have the origin at the top: drawing is flipped.
  func flipped(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: size.height - point.y) }

  let space = CGColorSpaceCreateDeviceRGB()
  let base = CGGradient(
    colorsSpace: space,
    colors: [
      NSColor(red: 0.52, green: 0.55, blue: 0.60, alpha: 1).cgColor,
      NSColor(red: 0.40, green: 0.43, blue: 0.49, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(
    base, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
  // A light halo behind each icon: it sets them apart from the background.
  for center in [appCenter, applicationsCenter] {
    let glow = CGGradient(
      colorsSpace: space,
      colors: [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
      locations: [0, 1])!
    ctx.drawRadialGradient(
      glow, startCenter: flipped(center), startRadius: 0, endCenter: flipped(center), endRadius: 150, options: [])
  }

  // Arrow between the two icons (128 pt each): dashed shaft and solid head.
  let y = size.height - appCenter.y
  let from = appCenter.x + 92
  let to = applicationsCenter.x - 92
  ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
  ctx.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
  ctx.setLineWidth(5)
  ctx.setLineCap(.round)
  ctx.setLineDash(phase: 0, lengths: [2, 12])
  ctx.move(to: CGPoint(x: from, y: y))
  ctx.addLine(to: CGPoint(x: to - 20, y: y))
  ctx.strokePath()
  ctx.setLineDash(phase: 0, lengths: [])
  ctx.setLineJoin(.round)
  ctx.move(to: CGPoint(x: to - 18, y: y + 13))
  ctx.addLine(to: CGPoint(x: to, y: y))
  ctx.addLine(to: CGPoint(x: to - 18, y: y - 13))
  ctx.closePath()
  ctx.drawPath(using: .fillStroke)

  func text(_ string: String, size fontSize: CGFloat, weight: NSFont.Weight, alpha: CGFloat, top: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = CGSize(width: 0, height: -1)
    let attributed = NSAttributedString(
      string: string,
      attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: paragraph, .shadow: shadow,
      ])
    let height = attributed.size().height
    attributed.draw(in: CGRect(x: 0, y: size.height - top - height, width: size.width, height: height))
  }
  text("Drag Tsukumo to the Applications folder", size: 22, weight: .semibold, alpha: 0.97, top: 34)
  text(
    "Then open it from Applications", size: 12, weight: .regular, alpha: 0.7,
    top: 372)
  _ = bounds
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: URL(fileURLWithPath: out).appendingPathComponent("background.png"))
try render(scale: 2).write(to: URL(fileURLWithPath: out).appendingPathComponent("background@2x.png"))
