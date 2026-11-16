// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import os

/// Real backend: `CGEvent.tapCreate` on `.cgSessionEventTap`, with one dedicated
/// thread per tap. The thread sleeps in its run loop until an event arrives.
public struct CGEventTapBackend: EventTapBackend {
  public init() {}

  public func install(kind: TapKind, mask: CGEventMask, dispatch: @escaping InputTapDispatch) -> (any InstalledTap)? {
    let tap = SessionTap(kind: kind, dispatch: dispatch)
    return tap.start(mask: mask) ? tap : nil
  }
}

private final class SessionTap: InstalledTap, @unchecked Sendable {
  private let kind: TapKind
  private let dispatch: InputTapDispatch
  // Protected by `lock`: the tap thread and whoever uninstalls hand the run loop to each other.
  private let lock = NSLock()
  private var runLoop: CFRunLoop?
  private var stopped = false
  // Written once in start(), before the thread starts; read-only afterwards.
  private var port: CFMachPort?
  private let signposter = OSSignposter(subsystem: "tsukumo.core", category: "input-tap")

  init(kind: TapKind, dispatch: @escaping InputTapDispatch) {
    self.kind = kind
    self.dispatch = dispatch
  }

  func start(mask: CGEventMask) -> Bool {
    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let tap = Unmanaged<SessionTap>.fromOpaque(refcon).takeUnretainedValue()
      return tap.handle(type: type, event: event)
    }
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: kind == .listen ? .listenOnly : .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else { return false }
    self.port = port

    // The thread keeps `self` alive as long as the run loop runs.
    let thread = Thread { [self] in runTapThread() }
    thread.name = "tsukumo.input-tap.\(kind.rawValue)"
    thread.qualityOfService = .userInteractive
    thread.start()
    return true
  }

  private func runTapThread() {
    guard let port else { return }
    let current = CFRunLoopGetCurrent()
    lock.lock()
    let shouldRun = !stopped
    if shouldRun { runLoop = current }
    lock.unlock()
    guard shouldRun else { return }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(current, source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    CFRunLoopRun()
  }

  func uninstall() {
    lock.lock()
    stopped = true
    let runLoop = runLoop
    lock.unlock()
    if let port {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    if let runLoop {
      CFRunLoopStop(runLoop)
    }
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    // The system disables a slow tap, or one after certain user inputs: re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port { CGEvent.tapEnable(tap: port, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    // Callback budget: 1 ms, measurable in Instruments with this interval.
    let interval = signposter.beginInterval("dispatch")
    defer { signposter.endInterval("dispatch", interval) }

    guard let result = dispatch(type, event) else { return nil }
    return result === event ? Unmanaged.passUnretained(event) : Unmanaged.passRetained(result)
  }
}
