// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import Foundation

/// Typed wrapper for the private SkyLight symbols we use (DESIGN.md
/// §2.1, §2.2.1, §4.1). Everything that may disappear in a macOS major release
/// goes through here, so `compat.json` + `health` can suspend it in
/// a single place.
///
/// Not a singleton: we create one per module that uses it, sharing a
/// `FrameworkHandle` upstream, so tests can build fake versions.
public enum SkyLightBridge {
  public static let frameworkPath =
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
  public static let shared = FrameworkHandle(path: frameworkPath)

  // MARK: - Symbolic system hotkeys (⌘⇥, etc.)

  private typealias SetSymbolicHotKeyEnabled = @convention(c) (Int32, Bool) -> Int32

  /// Enables/disables a system hotkey (⌘⇥ = 1, ⌘⇧⇥ = 2). `false` if
  /// the private API is missing on this macOS version.
  @discardableResult
  public static func setSymbolicHotKeyEnabled(_ id: Int32, _ enabled: Bool) -> Bool {
    guard let fn = shared.symbol("CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyEnabled.self) else {
      return false
    }
    _ = fn(id, enabled)
    return true
  }

  /// C pointer to the function, for callers that cannot do anything
  /// else (crash signal handlers, §2.2.1 point 5).
  public static var symbolicHotKeyFunction: (@convention(c) (Int32, Bool) -> Int32)? {
    shared.symbol("CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyEnabled.self)
  }

  public static var hasSymbolicHotKey: Bool {
    shared.symbol("CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyEnabled.self) != nil
  }

  // MARK: - Lock screen Space

  private typealias MainConnection = @convention(c) () -> Int32
  private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
  private typealias SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
  private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
  private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

  /// Absolute level of the private Space. 300 is the lock screen's own,
  /// 400 sits above (Notification Center level on a locked
  /// screen). The comment is in the calling code (DESIGN §2.1).
  public static let lockScreenAbsoluteLevel: Int32 = 400

  /// Spaces already created, by level. Only one is created per level and it is
  /// reused: creating a new one at every screen lock would accumulate them in
  /// WindowServer, because they are never destroyed.
  @MainActor private static var lockScreenSpaces: [Int32: Int32] = [:]

  /// Moves the given windows to a SkyLight Space at absolute level
  /// `level`, so they stay visible even with the screen locked. Returns `false`
  /// if one of the symbols is missing or creation fails.
  @MainActor
  @discardableResult
  public static func attachWindowsToLockScreenSpace(
    _ windows: [NSWindow], level: Int32 = lockScreenAbsoluteLevel
  ) -> Bool {
    guard
      let connection = shared.symbol("SLSMainConnectionID", as: MainConnection.self),
      let create = shared.symbol("SLSSpaceCreate", as: SpaceCreate.self),
      let setLevel = shared.symbol("SLSSpaceSetAbsoluteLevel", as: SetLevel.self),
      let show = shared.symbol("SLSShowSpaces", as: ShowSpaces.self),
      let add = shared.symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self)
    else { return false }
    let numbers = windows.map(\.windowNumber).filter { $0 > 0 }
    guard !numbers.isEmpty else { return false }
    let id = connection()
    let space: Int32
    if let existing = lockScreenSpaces[level] {
      space = existing
    } else {
      space = create(id, 1, 0)
      guard space != 0 else { return false }
      lockScreenSpaces[level] = space
      _ = setLevel(id, space, level)
      _ = show(id, [space] as CFArray)
    }
    _ = add(id, space, numbers as CFArray, 7)
    return true
  }

  // MARK: - Window focus via private Process Manager

  private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> CGError
  private typealias GetProcess = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
  private typealias PostEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> CGError

  /// Brings the process + window to the front with the private
  /// Process Manager and SkyLight APIs. Returns `false` (and the caller falls back to
  /// AppKit) if a symbol is missing.
  @discardableResult
  public static func setFrontProcess(pid: pid_t, window: CGWindowID) -> Bool {
    // `GetProcessForPID` is exposed by the executable itself through CoreServices:
    // RTLD_DEFAULT (`-2`) finds it without opening a framework.
    let processManagerHandle = UnsafeMutableRawPointer(bitPattern: -2)
    guard let setFront = shared.symbol("_SLPSSetFrontProcessWithOptions", as: SetFront.self),
      let getProcess = dlsym(processManagerHandle, "GetProcessForPID").map({
        unsafeBitCast($0, to: GetProcess.self)
      })
    else { return false }
    let postEvent = shared.symbol("SLPSPostEventRecordTo", as: PostEvent.self)
    var psn = [UInt32](repeating: 0, count: 2)
    return psn.withUnsafeMutableBytes { buffer -> Bool in
      guard let base = buffer.baseAddress, getProcess(pid, base) == noErr else { return false }
      guard setFront(base, window, 0x200) == .success else { return false }
      // Without these two events the app comes to the front but the window does not become
      // "key": the one the app had before would stay active.
      if let postEvent {
        var record = [UInt8](repeating: 0, count: 0xf8)
        record[0x04] = 0xf8
        record[0x3a] = 0x10
        withUnsafeBytes(of: window) { bytes in
          for (offset, byte) in bytes.enumerated() { record[0x3c + offset] = byte }
        }
        for index in 0x20..<0x30 { record[index] = 0xff }
        record[0x08] = 0x01
        _ = postEvent(base, &record)
        record[0x08] = 0x02
        _ = postEvent(base, &record)
      }
      return true
    }
  }
}
