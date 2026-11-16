// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics

/// Combination that opens the switcher: the held modifier plus ⇥.
public enum SwitcherTrigger: String, Codable, Sendable, CaseIterable {
  /// Default: does not touch the system switcher.
  case optionTab
  /// Replaces the system ⌘⇥ (private API, crash-safe restore §2.2.1).
  case commandTab

  var modifier: CGEventFlags { self == .optionTab ? .maskAlternate : .maskCommand }
}

/// What to ask the graphical side after a keyboard event.
enum SwitcherAction: Equatable, Sendable {
  /// Open with the selection moved by `step` (1 = next window, -1 = the last).
  case open(step: Int)
  case move(Int)
  case confirm
  case cancel
}

/// Key state machine. Runs on the tap thread: O(1), no
/// allocation. It decides on its own whether the switcher is open, so the consumption of
/// events does not depend on the MainActor.
struct SwitcherKeys: Sendable {
  enum Key {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let returnKey: Int64 = 36
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
  }

  var trigger: SwitcherTrigger
  private(set) var isOpen = false
  /// The last Tab keyDown was consumed: its keyUp is ours too.
  /// If instead it passed (⌃ or the other modifier pressed) the keyUp must pass.
  private var swallowedTabDown = false

  init(trigger: SwitcherTrigger) {
    self.trigger = trigger
  }

  /// Other modifiers that, if pressed, exclude opening (⌃, and the other of ⌥ and ⌘).
  private var excluded: CGEventFlags {
    let others: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    return others.subtracting(trigger.modifier)
  }

  /// Result of an event: the action to perform and whether the event must be consumed.
  mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> (
    action: SwitcherAction?, consume: Bool
  ) {
    let held = flags.contains(trigger.modifier)
    switch type {
    case .flagsChanged:
      // Releasing the modifier confirms the choice. The event always passes.
      if isOpen, !held {
        isOpen = false
        return (.confirm, false)
      }
      return (nil, false)

    case .keyDown:
      let result = keyDown(keyCode, flags: flags, held: held)
      if keyCode == Key.tab { swallowedTabDown = result.consume }
      return result

    case .keyUp:
      // With the switcher open the releases stay ours too; after closing
      // only the release of the Tab whose press we consumed.
      if keyCode == Key.tab {
        let consume = isOpen || swallowedTabDown
        swallowedTabDown = false
        return (nil, consume)
      }
      return (nil, isOpen)

    default:
      return (nil, false)
    }
  }

  private mutating func keyDown(_ keyCode: Int64, flags: CGEventFlags, held: Bool) -> (
    action: SwitcherAction?, consume: Bool
  ) {
    let back = flags.contains(.maskShift)
    if !isOpen {
      guard keyCode == Key.tab, held, flags.isDisjoint(with: excluded) else { return (nil, false) }
      isOpen = true
      return (.open(step: back ? -1 : 1), true)
    }
    // Open but without the modifier: the release was lost (tap disabled,
    // Secure Event Input). It closes and the key passes, otherwise the switcher
    // would swallow the whole keyboard.
    guard held else {
      isOpen = false
      return (.cancel, false)
    }
    switch keyCode {
    case Key.tab: return (.move(back ? -1 : 1), true)
    case Key.right, Key.down: return (.move(1), true)
    case Key.left, Key.up: return (.move(-1), true)
    case Key.returnKey:
      isOpen = false
      return (.confirm, true)
    case Key.escape:
      isOpen = false
      return (.cancel, true)
    default:
      // Every other key with the switcher open is ignored and consumed.
      return (nil, true)
    }
  }

  /// Close from the graphical side (click, tap lost): the next ⇥ reopens.
  mutating func reset() {
    isOpen = false
  }
}
