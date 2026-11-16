// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Carbon.HIToolbox
import Foundation

public struct Hotkey: Codable, Hashable, Sendable {
  public let keyCode: UInt32
  public let modifiers: UInt32

  public init(keyCode: UInt32, modifiers: UInt32) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// Rules from DESIGN.md §4.3: a modifier alone is not a hotkey, and the
  /// combination must contain ⌘ or ⌃. ⌥-only and ⌥⇧ combinations have been
  /// blocked or intermittent since Sequoia; those without modifiers would steal
  /// the key from the whole system.
  public var isSupported: Bool {
    let modifierKeys = [
      kVK_Option, kVK_RightOption, kVK_Shift, kVK_RightShift, kVK_Command, kVK_RightCommand,
      kVK_Control, kVK_RightControl, kVK_Function, kVK_CapsLock,
    ].map(UInt32.init)
    guard !modifierKeys.contains(keyCode) else { return false }
    return modifiers & UInt32(cmdKey | controlKey) != 0
  }
}

public enum HotkeyError: Error, Equatable {
  case unsupportedCombination
  case duplicate(Hotkey)
  case systemConflict(OSStatus)
  case registrationFailed(OSStatus)
}

@MainActor
public final class HotkeySubscription {
  private var cancellation: (@MainActor () -> Void)?

  fileprivate init(cancellation: @escaping @MainActor () -> Void) {
    self.cancellation = cancellation
  }

  public func cancel() {
    cancellation?()
    cancellation = nil
  }
}

/// Centralized Carbon registration with internal conflict checking.
@MainActor
public final class Hotkeys {
  /// Instance shared for the whole life of the process; the Carbon handler keeps
  /// the callback context until the app quits.
  public static let shared = Hotkeys()

  private struct Registration {
    let hotkey: Hotkey
    let reference: EventHotKeyRef
    let handler: @MainActor () -> Void
  }

  private var registrations: [UInt32: Registration] = [:]
  private var nextID: UInt32 = 0
  private var eventHandler: EventHandlerRef?

  public init() {}

  private func installEventHandler() -> OSStatus {
    guard eventHandler == nil else { return noErr }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    return InstallEventHandler(
      GetApplicationEventTarget(), Self.dispatch, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler
    )
  }

  public func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) throws -> HotkeySubscription {
    guard hotkey.isSupported else { throw HotkeyError.unsupportedCombination }
    guard !registrations.values.contains(where: { $0.hotkey == hotkey }) else { throw HotkeyError.duplicate(hotkey) }
    let handlerStatus = installEventHandler()
    guard handlerStatus == noErr else { throw HotkeyError.registrationFailed(handlerStatus) }

    nextID &+= 1
    let id = nextID
    var reference: EventHotKeyRef?
    let identifier = EventHotKeyID(signature: OSType(0x54534B4D), id: id)
    let status = RegisterEventHotKey(
      hotkey.keyCode, hotkey.modifiers, identifier, GetApplicationEventTarget(), 0, &reference
    )
    guard status == noErr, let reference else {
      if registrations.isEmpty, let eventHandler {
        RemoveEventHandler(eventHandler)
        self.eventHandler = nil
      }
      throw status == eventHotKeyExistsErr ? HotkeyError.systemConflict(status) : HotkeyError.registrationFailed(status)
    }
    registrations[id] = Registration(hotkey: hotkey, reference: reference, handler: handler)
    return HotkeySubscription { [weak self] in self?.unregister(id) }
  }

  private func unregister(_ id: UInt32) {
    guard let registration = registrations.removeValue(forKey: id) else { return }
    UnregisterEventHotKey(registration.reference)
    if registrations.isEmpty, let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  private static let dispatch: EventHandlerUPP = { _, event, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
      event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
      MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID
    )
    guard status == noErr else { return status }
    let service = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in service.registrations[hotkeyID.id]?.handler() }
    return noErr
  }

}

extension ResourceBag {
  @discardableResult
  public func addHotkey(_ subscription: HotkeySubscription) -> Token {
    add(.subscription) { subscription.cancel() }
  }
}
