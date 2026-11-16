// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-FileCopyrightText: 2026 fx-xf
// SPDX-License-Identifier: GPL-3.0-only
//
// Inspired by DesktopCapture from fx-xf/duo (MIT), see THIRD-PARTY-NOTICES.md.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// A single frame of the screen, taken at the start of the movement and held still
/// under the effect (DESIGN.md §2.4): no stream, so no cost between one
/// session and the next and no prolonged recording indicator.
@MainActor
final class ScreenSnapshot {
  private let onFrame: @Sendable (CVPixelBuffer) -> Void
  private var generation = 0
  private(set) var isCapturing = false

  init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
    self.onFrame = onFrame
  }

  /// Captures the display asynchronously. A new request invalidates the one in progress.
  func capture(displayID: CGDirectDisplayID, pixelSize: CGSize, hiding hiddenWindows: [CGWindowID] = []) {
    generation += 1
    let attempt = generation
    isCapturing = true
    Task {
      defer { if attempt == self.generation { self.isCapturing = false } }
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard
          let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else { return }
        let hidden = content.windows.filter { hiddenWindows.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.showsCursor = false
        configuration.scalesToFit = false

        let sample = try await SCScreenshotManager.captureSampleBuffer(
          contentFilter: filter, configuration: configuration)
        guard attempt == self.generation, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        self.onFrame(buffer)
      } catch {
        // Without permission or with the display off there is nothing to bend: the overlay stays hidden.
      }
    }
  }

  func cancel() {
    generation += 1
    isCapturing = false
  }

  static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
}
