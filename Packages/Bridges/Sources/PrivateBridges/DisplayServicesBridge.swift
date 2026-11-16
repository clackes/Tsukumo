// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Brightness of the built-in display: macOS has no public API to set it,
/// so it goes through `DisplayServices` (private, DESIGN.md §2.1).
public enum DisplayServicesBridge {
  public static let frameworkPath =
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
  public static let shared = FrameworkHandle(path: frameworkPath)

  private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

  public static var isAvailable: Bool {
    shared.symbol("DisplayServicesGetBrightness", as: Getter.self) != nil
  }

  /// First built-in display that answers `GetBrightness`.
  public static func builtInDisplay() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
    return displays.prefix(Int(count)).first {
      CGDisplayIsBuiltin($0) != 0 && brightness(of: $0) != nil
    }
  }

  public static func brightness(of display: CGDirectDisplayID) -> Float? {
    guard let getter = shared.symbol("DisplayServicesGetBrightness", as: Getter.self) else { return nil }
    var value: Float = 0
    return getter(display, &value) == 0 ? value : nil
  }

  @discardableResult
  public static func setBrightness(_ value: Float, display: CGDirectDisplayID) -> Bool {
    guard let setter = shared.symbol("DisplayServicesSetBrightness", as: Setter.self) else { return false }
    return setter(display, min(max(value, 0), 1)) == 0
  }
}
