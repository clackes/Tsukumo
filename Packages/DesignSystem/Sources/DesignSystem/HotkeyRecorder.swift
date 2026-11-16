// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Carbon.HIToolbox
import ModuleKit
import SwiftUI

/// Native hotkey recording field. Captures the combination only while
/// the control is selected and rejects isolated modifier keys.
public struct HotkeyRecorder: View {
  @Binding private var hotkey: Hotkey?
  private let onClear: (() -> Void)?

  public init(hotkey: Binding<Hotkey?>, onClear: (() -> Void)? = nil) {
    _hotkey = hotkey
    self.onClear = onClear
  }

  public var body: some View {
    HStack(spacing: TsukumoTokens.Spacing.sm) {
      RecorderField(hotkey: $hotkey)
        .frame(width: 190, height: 30)
      if let onClear {
        Button("Remove shortcut", systemImage: "xmark.circle") { onClear() }
          .labelStyle(.iconOnly)
          .help("Remove shortcut")
      }
    }
  }
}

private struct RecorderField: NSViewRepresentable {
  @Binding var hotkey: Hotkey?

  func makeNSView(context: Context) -> RecorderNSView {
    let view = RecorderNSView()
    view.onRecord = { hotkey = $0 }
    view.hotkey = hotkey
    return view
  }

  func updateNSView(_ view: RecorderNSView, context: Context) {
    view.hotkey = hotkey
  }
}

private final class RecorderNSView: NSView {
  var hotkey: Hotkey? { didSet { needsDisplay = true } }
  var onRecord: ((Hotkey) -> Void)?
  private var isRecording = false

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    isRecording = true
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else { super.keyDown(with: event); return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.option) { modifiers |= UInt32(optionKey) }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    if flags.contains(.control) { modifiers |= UInt32(controlKey) }
    let candidate = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    guard candidate.isSupported, modifiers != 0 else { NSSound.beep(); return }
    hotkey = candidate
    onRecord?(candidate)
    isRecording = false
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let bounds = bounds.insetBy(dx: 1, dy: 1)
    let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
    (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
    shape.fill()
    (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    shape.lineWidth = isRecording ? 2 : 1
    shape.stroke()

    let title = isRecording ? "Press a key combination…" : hotkey.map(Self.displayName) ?? "Record shortcut"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
    ]
    let size = title.size(withAttributes: attributes)
    title.draw(
      at: NSPoint(x: max(8, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2),
      withAttributes: attributes)
  }

  private static func displayName(_ hotkey: Hotkey) -> String {
    var result = ""
    if hotkey.modifiers & UInt32(controlKey) != 0 { result += "⌃" }
    if hotkey.modifiers & UInt32(optionKey) != 0 { result += "⌥" }
    if hotkey.modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
    if hotkey.modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
    let key = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let layout = TISGetInputSourceProperty(key, kTISPropertyUnicodeKeyLayoutData)
    if let layout, let data = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data? {
      result += character(for: UInt16(hotkey.keyCode), layout: data) ?? "Tasto \(hotkey.keyCode)"
    } else {
      result += "Tasto \(hotkey.keyCode)"
    }
    return result
  }

  private static func character(for keyCode: UInt16, layout: Data) -> String? {
    layout.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> String? in
      guard let base = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
      var deadKeyState: UInt32 = 0
      var chars = [UniChar](repeating: 0, count: 4)
      var length = 0
      let status = UCKeyTranslate(
        base, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
      )
      guard status == noErr, length > 0 else { return nil }
      return String(utf16CodeUnits: chars, count: length).uppercased()
    }
  }
}
