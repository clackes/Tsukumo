// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Testing

@testable import Convert

@Suite("Crop: geometry")
struct CropGeometryTests {
  let size = CGSize(width: 400, height: 300)

  @Test("starts from the full image")
  func initial() {
    let geo = CropGeometry(imageSize: size)
    #expect(geo.rect == CGRect(origin: .zero, size: size))
    #expect(geo.normalizedRect == CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  @Test("the 1:1 ratio gives a square inside the image, centered")
  func squareAspect() {
    var geo = CropGeometry(imageSize: size)
    geo.setAspect(.square)
    #expect(abs(geo.rect.width - geo.rect.height) < 0.001)
    #expect(geo.rect.width <= 300.001)
    #expect(abs(geo.rect.midX - 200) < 0.001)
    #expect(CGRect(origin: .zero, size: size).contains(geo.rect))
  }

  @Test("Original has the image's ratio; fixed ones have their own")
  func ratios() {
    #expect(abs((CropGeometry.Aspect.original.ratio(for: size) ?? 0) - 4.0 / 3.0) < 0.0001)
    #expect(CropGeometry.Aspect.free.ratio(for: size) == nil)
    #expect(abs((CropGeometry.Aspect.sixteenNine.ratio(for: size) ?? 0) - 16.0 / 9.0) < 0.0001)
    #expect(abs((CropGeometry.Aspect.nineSixteen.ratio(for: size) ?? 0) - 9.0 / 16.0) < 0.0001)
  }

  @Test("a free corner stops at the edges and at the minimum size")
  func freeCorner() {
    let geo = CropGeometry(imageSize: size, rect: CGRect(x: 100, y: 100, width: 100, height: 100))
    let grown = geo.resizing(.bottomRight, to: CGPoint(x: 900, y: 900))
    #expect(grown == CGRect(x: 100, y: 100, width: 300, height: 200))
    let shrunk = geo.resizing(.bottomRight, to: CGPoint(x: 90, y: 90))
    #expect(shrunk.width == CropGeometry.minimumSide)
    #expect(shrunk.height == CropGeometry.minimumSide)
    #expect(shrunk.origin == CGPoint(x: 100, y: 100))
    let top = geo.resizing(.topLeft, to: CGPoint(x: -50, y: -50))
    #expect(top == CGRect(x: 0, y: 0, width: 200, height: 200))
  }

  @Test("a free side changes only that side")
  func freeEdge() {
    let geo = CropGeometry(imageSize: size, rect: CGRect(x: 100, y: 100, width: 100, height: 100))
    #expect(geo.resizing(.right, to: CGPoint(x: 250, y: 0)) == CGRect(x: 100, y: 100, width: 150, height: 100))
    #expect(geo.resizing(.left, to: CGPoint(x: 40, y: 0)) == CGRect(x: 40, y: 100, width: 160, height: 100))
    #expect(geo.resizing(.top, to: CGPoint(x: 0, y: 20)) == CGRect(x: 100, y: 20, width: 100, height: 180))
    #expect(geo.resizing(.bottom, to: CGPoint(x: 0, y: 999)) == CGRect(x: 100, y: 100, width: 100, height: 200))
  }

  @Test("with a fixed ratio the corners keep it and stay within the edges")
  func lockedCorner() {
    var geo = CropGeometry(imageSize: size, rect: CGRect(x: 50, y: 50, width: 100, height: 100))
    geo.setAspect(.sixteenNine)
    let start = geo.rect
    for target in [CGPoint(x: 380, y: 200), CGPoint(x: 900, y: 900), CGPoint(x: 120, y: 280)] {
      let out = geo.resizing(.bottomRight, to: target)
      #expect(abs(out.width / out.height - 16.0 / 9.0) < 0.001)
      #expect(CGRect(origin: .zero, size: size).contains(out.insetBy(dx: 0.001, dy: 0.001)))
      #expect(out.minX == start.minX && out.minY == start.minY)
    }
    let tiny = geo.resizing(.bottomRight, to: CGPoint(x: 0, y: 0))
    #expect(tiny.height >= CropGeometry.minimumSide - 0.001)
    #expect(abs(tiny.width / tiny.height - 16.0 / 9.0) < 0.001)
  }

  @Test("with a fixed ratio one side also resizes the other axis")
  func lockedEdge() {
    var geo = CropGeometry(imageSize: size, rect: CGRect(x: 100, y: 100, width: 100, height: 100))
    geo.setAspect(.square)
    let out = geo.resizing(.right, to: CGPoint(x: 260, y: 0))
    #expect(abs(out.width - 160) < 0.001)
    #expect(abs(out.height - 160) < 0.001)
    #expect(abs(out.midY - geo.rect.midY) < 0.001)
    // The centre is at y=150: the square cannot exceed 300 on a side nor leave the image.
    let huge = geo.resizing(.right, to: CGPoint(x: 400, y: 0))
    #expect(huge.minY >= 0 && huge.maxY <= 300 && huge.maxX <= 400)
    #expect(abs(huge.width - huge.height) < 0.001)
  }

  @Test("moving stays inside the image")
  func move() {
    let geo = CropGeometry(imageSize: size, rect: CGRect(x: 100, y: 100, width: 100, height: 100))
    #expect(geo.moved(by: CGSize(width: 20, height: -10)) == CGRect(x: 120, y: 90, width: 100, height: 100))
    #expect(geo.moved(by: CGSize(width: 999, height: 999)) == CGRect(x: 300, y: 200, width: 100, height: 100))
    #expect(geo.moved(by: CGSize(width: -999, height: -999)).origin == .zero)
  }

  @Test("a 90° rotation carries the crop with it")
  func rotation() {
    var geo = CropGeometry(imageSize: size, rect: CGRect(x: 10, y: 20, width: 100, height: 50))
    geo.rotate(clockwise: true)
    #expect(geo.imageSize == CGSize(width: 300, height: 400))
    #expect(geo.rect == CGRect(x: 230, y: 10, width: 50, height: 100))
    geo.rotate(clockwise: false)
    #expect(geo.imageSize == size)
    #expect(geo.rect == CGRect(x: 10, y: 20, width: 100, height: 50))
  }

  @Test("flipping mirrors the crop")
  func flip() {
    var geo = CropGeometry(imageSize: size, rect: CGRect(x: 10, y: 20, width: 100, height: 50))
    geo.flipHorizontally()
    #expect(geo.rect == CGRect(x: 290, y: 20, width: 100, height: 50))
  }

  @Test("handles are recognized: corners before sides, then nothing")
  func hitTest() {
    let box = CGRect(x: 100, y: 100, width: 200, height: 100)
    #expect(CropGeometry.handle(at: CGPoint(x: 102, y: 103), in: box, tolerance: 10) == .topLeft)
    #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 98), in: box, tolerance: 10) == .top)
    #expect(CropGeometry.handle(at: CGPoint(x: 298, y: 150), in: box, tolerance: 10) == .right)
    #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 150), in: box, tolerance: 10) == nil)
  }
}
