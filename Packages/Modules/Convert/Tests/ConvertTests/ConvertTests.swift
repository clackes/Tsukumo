// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import Convert

@Suite("Convert: catalog and names")
struct ConvertCatalogTests {
  private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

  @Test("an image offers all formats except its own")
  func imageFormats() {
    let formats = ConvertCatalog.formats(for: [url("photo.png")])
    #expect(!formats.contains(.png))
    #expect(formats.contains(.jpeg))
    #expect(formats.contains(.pdf))
  }

  @Test("images of different formats also offer those formats")
  func mixedImages() {
    #expect(ConvertCatalog.formats(for: [url("a.png"), url("b.jpg")]).contains(.png))
  }

  @Test("a PDF offers image formats; mixed or unknown files offer nothing")
  func pdfAndOthers() {
    #expect(ConvertCatalog.formats(for: [url("doc.pdf")]) == ConvertCatalog.pdfFormats)
    #expect(ConvertCatalog.formats(for: [url("doc.pdf"), url("a.png")]).isEmpty)
    #expect(ConvertCatalog.formats(for: [url("note.txt")]).isEmpty)
    #expect(ConvertCatalog.formats(for: []).isEmpty)
  }

  @Test("the output name never overwrites")
  func naming() {
    let source = url("photo.png")
    #expect(OutputNamer.url(for: source, extension: "jpg", exists: { _ in false }).lastPathComponent == "photo.jpg")
    let taken: Set<String> = ["photo.jpg", "photo 2.jpg"]
    let next = OutputNamer.url(for: source, extension: "jpg", exists: { taken.contains($0.lastPathComponent) })
    #expect(next.lastPathComponent == "photo 3.jpg")
    #expect(OutputNamer.url(for: source, extension: "png", exists: { _ in false }).lastPathComponent == "photo 2.png")
    #expect(
      OutputNamer.url(for: url("doc.pdf"), extension: "png", suffix: "-2", exists: { _ in false }).lastPathComponent
        == "doc-2.png")
  }
}

@Suite("Convert: picker geometry")
struct RadialLayoutTests {
  let layout = RadialLayout(petals: 8)

  @Test("the first petal is at the top, then clockwise")
  func petals() {
    #expect(layout.petal(at: CGPoint(x: 0, y: -100)) == 0)
    #expect(layout.petal(at: CGPoint(x: 100, y: 0)) == 2)
    #expect(layout.petal(at: CGPoint(x: 0, y: 100)) == 4)
    #expect(layout.petal(at: CGPoint(x: -100, y: 0)) == 6)
    #expect(layout.petal(at: CGPoint(x: -20, y: -100)) == 0)
  }

  @Test("there is no petal at the center or far away")
  func outside() {
    #expect(layout.petal(at: .zero) == nil)
    #expect(layout.petal(at: CGPoint(x: 0, y: -30)) == nil)
    #expect(layout.petal(at: CGPoint(x: 0, y: -300)) == nil)
    #expect(RadialLayout(petals: 0).petal(at: CGPoint(x: 0, y: -100)) == nil)
  }
}

@Suite("Convert: conversion")
struct ImageConverterTests {
  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("convert-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Semi-transparent 4×4 PNG.
  private func writePNG(in folder: URL) throws -> URL {
    let context = try #require(
      CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = try #require(context.makeImage())
    let url = folder.appendingPathComponent("prova.png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
  }

  @Test("PNG to JPG, HEIC and PDF next to the original")
  func convertImage() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = try writePNG(in: folder)
    for format in [OutputFormat.jpeg, .heic, .pdf] {
      let outputs = try ImageConverter.convert(png, to: format)
      #expect(outputs.count == 1)
      #expect(outputs[0].pathExtension == format.fileExtension)
      #expect(FileManager.default.fileExists(atPath: outputs[0].path))
    }
    #expect(FileManager.default.fileExists(atPath: png.path))
  }

  @Test("a two-page PDF becomes two numbered images")
  func convertPDF() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = try writePNG(in: folder)
    let image = try #require(NSImage(contentsOf: png))
    let document = PDFDocument()
    document.insert(try #require(PDFPage(image: image)), at: 0)
    document.insert(try #require(PDFPage(image: image)), at: 1)
    let pdf = folder.appendingPathComponent("doc.pdf")
    #expect(document.write(to: pdf))
    let outputs = try ImageConverter.convert(pdf, to: .png)
    #expect(outputs.map(\.lastPathComponent) == ["doc-1.png", "doc-2.png"])
  }

  @Test("an unreadable file gives an error, not an empty file")
  func unreadable() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let fake = folder.appendingPathComponent("rotto.png")
    try Data("not an image".utf8).write(to: fake)
    #expect(throws: ConversionError.unreadable("rotto.png")) { try ImageConverter.convert(fake, to: .jpeg) }
  }
}
