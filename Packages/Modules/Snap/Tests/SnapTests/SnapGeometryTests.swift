// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Testing

@testable import Snap

@Suite("Snap")
struct SnapGeometryTests {
  let area = CGRect(x: 0, y: 25, width: 1441, height: 875)
  let screen = CGRect(x: 0, y: 0, width: 1441, height: 900)

  @Test("the two halves cover the whole area without overlapping, even with odd widths")
  func halvesTile() throws {
    let left = try #require(SnapGeometry.frame(for: .leftHalf, current: .zero, in: area))
    let right = try #require(SnapGeometry.frame(for: .rightHalf, current: .zero, in: area))
    #expect(left.minX == area.minX && right.maxX == area.maxX)
    #expect(left.maxX == right.minX)
    #expect(left.height == area.height && right.height == area.height)
  }

  @Test("the four quarters cover the area")
  func quartersTile() throws {
    let frames = try [SnapAction.topLeft, .topRight, .bottomLeft, .bottomRight].map {
      try #require(SnapGeometry.frame(for: $0, current: .zero, in: area))
    }
    #expect(frames.reduce(0) { $0 + $1.width * $1.height } == area.width * area.height)
    #expect(frames.reduce(CGRect.null) { $0.union($1) } == area)
  }

  @Test("centers without resizing, but not beyond the area")
  func center() throws {
    let small = try #require(
      SnapGeometry.frame(for: .center, current: CGRect(x: 5, y: 5, width: 400, height: 300), in: area))
    #expect(small.size == CGSize(width: 400, height: 300))
    #expect(abs(small.midX - area.midX) <= 1 && abs(small.midY - area.midY) <= 1)
    let huge = try #require(
      SnapGeometry.frame(for: .center, current: CGRect(x: 0, y: 0, width: 5000, height: 5000), in: area))
    #expect(huge == area)
  }

  @Test("full screen and restore")
  func maximizeAndRestore() {
    #expect(SnapGeometry.frame(for: .maximize, current: .zero, in: area) == area)
    #expect(SnapGeometry.frame(for: .restore, current: .zero, in: area) == nil)
  }

  @Test("an edge shared with another monitor doesn't snap; the others do")
  func sharedEdgesIgnored() {
    let right = CGPoint(x: 1440, y: 450)
    #expect(SnapGeometry.action(at: right, in: screen, ignoring: .right) == nil)
    #expect(SnapGeometry.action(at: CGPoint(x: 0, y: 450), in: screen, ignoring: .right) == .leftHalf)
    #expect(SnapGeometry.action(at: CGPoint(x: 700, y: 0), in: screen, ignoring: .top) == nil)
    // The corner stays reachable from the unshared edge.
    #expect(SnapGeometry.action(at: CGPoint(x: 1430, y: 0), in: screen, ignoring: .right) == .topRight)
  }

  @Test("edge zones: sides, corners, top edge; nothing in the center or at the bottom")
  func edgeZones() {
    #expect(SnapGeometry.action(at: CGPoint(x: 0, y: 450), in: screen) == .leftHalf)
    #expect(SnapGeometry.action(at: CGPoint(x: 1440, y: 450), in: screen) == .rightHalf)
    #expect(SnapGeometry.action(at: CGPoint(x: 700, y: 0), in: screen) == .maximize)
    #expect(SnapGeometry.action(at: CGPoint(x: 2, y: 30), in: screen) == .topLeft)
    #expect(SnapGeometry.action(at: CGPoint(x: 60, y: 1), in: screen) == .topLeft)
    #expect(SnapGeometry.action(at: CGPoint(x: 1439, y: 880), in: screen) == .bottomRight)
    #expect(SnapGeometry.action(at: CGPoint(x: 700, y: 450), in: screen) == nil)
    #expect(SnapGeometry.action(at: CGPoint(x: 700, y: 899), in: screen) == nil)
    #expect(SnapGeometry.action(at: CGPoint(x: 3000, y: 450), in: screen) == nil)
  }

  @Test("containment in screens includes the max edges, like NSMouseInRect")
  func inclusiveScreenEdges() {
    #expect(ScreenSpace.contains(screen, CGPoint(x: 700, y: 900)))
    #expect(ScreenSpace.contains(screen, CGPoint(x: 1441, y: 0)))
    #expect(!ScreenSpace.contains(screen, CGPoint(x: 700, y: 900.5)))
  }
}
