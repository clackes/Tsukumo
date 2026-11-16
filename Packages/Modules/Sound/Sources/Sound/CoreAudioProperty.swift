// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Foundation

/// Small helpers on top of `AudioObjectGetPropertyData` and friends.
enum CoreAudioProperty {
  static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }

  static func read<Value: BitwiseCopyable>(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: Value
  ) -> Value? {
    var address = address
    var value = initial
    var size = UInt32(MemoryLayout<Value>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
  }

  static func write<Value: BitwiseCopyable>(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, value: Value
  ) -> Bool {
    var address = address
    var value = value
    return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &value) == noErr
  }

  static func dataSize(of object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32 {
    var address = address
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return 0 }
    return size
  }

  static func array<Element: FixedWidthInteger>(of object: AudioObjectID, _ address: AudioObjectPropertyAddress)
    -> [Element]
  {
    var address = address
    var bytes = dataSize(of: object, address)
    guard bytes > 0 else { return [] }
    var values = [Element](repeating: 0, count: Int(bytes) / MemoryLayout<Element>.stride)
    let status = values.withUnsafeMutableBytes { buffer -> OSStatus in
      guard let base = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
      return AudioObjectGetPropertyData(object, &address, 0, nil, &bytes, base)
    }
    return status == noErr ? values : []
  }

  static func string(of object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
    guard let value = read(object, address, initial: Unmanaged<CFString>?.none) else { return nil }
    return value?.takeRetainedValue() as String?
  }

  /// The addresses of a control (volume, mute) of the device, in order
  /// of preference: master if it exists and is writable, otherwise channels 1 and 2.
  static func controls(of object: AudioObjectID, selectors: [AudioObjectPropertySelector])
    -> [AudioObjectPropertyAddress]
  {
    for selector in selectors {
      let main = address(selector, scope: kAudioObjectPropertyScopeOutput)
      if isSettable(object, main) { return [main] }
    }
    for selector in selectors {
      let channels = (1...2).map { address(selector, scope: kAudioObjectPropertyScopeOutput, element: $0) }
      let usable = channels.filter { isSettable(object, $0) }
      if !usable.isEmpty { return usable }
    }
    return []
  }

  static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var address = address
    guard AudioObjectHasProperty(object, &address) else { return false }
    var settable: DarwinBoolean = false
    return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
  }
}
