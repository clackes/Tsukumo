// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import Darwin
import DesignSystem
import ModuleKit
import SwiftUI

/// Management of macOS 27's native "Allow in the menu bar" toggles.
/// Reading and writing happen only when the Settings page is open.
@MainActor
final class MenuBarPreferences {
  private typealias CopyValue =
    @convention(c) (
      CFString, CFString, CFString, CFString, CFString
    ) -> Unmanaged<CFPropertyList>?
  private typealias SetValue =
    @convention(c) (
      CFString, CFPropertyList?, CFString, CFString, CFString, CFString
    ) -> Void
  private typealias Synchronize =
    @convention(c) (
      CFString, CFString, CFString, CFString
    ) -> Bool

  private struct Functions {
    let copy: CopyValue
    let set: SetValue
    let synchronize: Synchronize

    static let shared: Functions? = {
      guard
        let handle = dlopen(
          "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW),
        let copy = dlsym(handle, "_CFPreferencesCopyValueWithContainer"),
        let set = dlsym(handle, "_CFPreferencesSetValueWithContainer"),
        let synchronize = dlsym(handle, "_CFPreferencesSynchronizeWithContainer")
      else { return nil }
      return Functions(
        copy: unsafeBitCast(copy, to: CopyValue.self),
        set: unsafeBitCast(set, to: SetValue.self),
        synchronize: unsafeBitCast(synchronize, to: Synchronize.self)
      )
    }()
  }

  private let key = "trackedApplications" as CFString
  private let domain = "group.com.apple.controlcenter" as CFString
  private var container: CFString {
    (NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter") as CFString
  }

  var canAccessContainer: Bool {
    let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter"
    do {
      _ = try FileManager.default.contentsOfDirectory(atPath: path)
      return true
    } catch {
      return false
    }
  }

  /// Identifier of an entry: bundle id, or the `file://` URL of the executable
  /// for processes without a bundle (`adhocBinary` key, e.g. PaperCut).
  nonisolated static func identifier(of key: Any) -> String? {
    guard let key = key as? [String: Any], key.count == 1 else { return nil }
    if let bundle = key["bundle"] as? [String: Any] { return bundle["_0"] as? String }
    if let binary = key["adhocBinary"] as? [String: Any], let url = binary["_0"] as? [String: Any] {
      return url["relative"] as? String
    }
    return nil
  }

  /// Folder of the app an executable without a bundle belongs to
  /// (`file:///Applications/PaperCut…/v2026…/usercontextservice` →
  /// `/Applications/PaperCut…`). These programs change path at every
  /// update and have several executables: for macOS they are different entries, for
  /// the user it is the same icon. `nil` for bundle ids.
  nonisolated static func family(of identifier: String) -> String? {
    guard identifier.hasPrefix("file:"), let url = URL(string: identifier) else { return nil }
    let parts = url.pathComponents
    if let index = parts.firstIndex(of: "Applications"), parts.indices.contains(index + 2) {
      return "/" + parts[1...(index + 1)].joined(separator: "/")
    }
    return url.deletingLastPathComponent().path
  }

  func read() throws -> [String: Bool] { try Self.readStates() }

  /// State of each entry (`isAllowed`). It does not touch the object's state, so it
  /// can be called off the main thread: the page does so to avoid blocking.
  nonisolated static func readStates() throws -> [String: Bool] {
    guard let functions = Functions.shared else { throw MenuBarPreferenceError.unavailable }
    let home = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter"
    guard
      let value = functions.copy(
        "trackedApplications" as CFString, "group.com.apple.controlcenter" as CFString,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost, home as CFString
      )?.takeRetainedValue()
    else { throw MenuBarPreferenceError.preferenceMissing }
    guard let data = value as? Data else { throw MenuBarPreferenceError.invalidData }
    guard let array = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
    else { throw MenuBarPreferenceError.invalidData }

    var result = [String: Bool]()
    guard array.count >= 2 else { return result }
    for index in stride(from: 0, to: array.count - 1, by: 2) {
      guard
        let bundleID = identifier(of: array[index]),
        let value = array[index + 1] as? [String: Any],
        let allowed = value["isAllowed"] as? Bool
      else { continue }
      result[bundleID] = (result[bundleID] ?? false) || allowed
    }
    return result
  }

  /// Changes `isAllowed` in the entries of `trackedApplications` (key, value
  /// pairs in a flat array) and adds the missing ones.
  /// - Returns: `false` if there was nothing to change.
  nonisolated static func apply(_ allowed: Bool, to bundleIDs: Set<String>, in array: inout [Any]) -> Bool {
    // An executable without a bundle applies to its whole family: otherwise
    // after an app update the switch would act on the old entry
    // and the icon would stay where it is.
    let families = Set(bundleIDs.compactMap(family(of:)))
    var matchedFamilies = Set<String>()
    var registeredIDs = Set<String>()
    var didChange = false
    for index in stride(from: 0, to: array.count - 1, by: 2) {
      guard let identifier = identifier(of: array[index]) else { continue }
      registeredIDs.insert(identifier)
      let family = family(of: identifier)
      guard bundleIDs.contains(identifier) || family.map(families.contains) == true,
        var value = array[index + 1] as? [String: Any]
      else { continue }
      if let family { matchedFamilies.insert(family) }
      value["isAllowed"] = allowed
      array[index + 1] = value
      didChange = true
    }
    for bundleID in bundleIDs.subtracting(registeredIDs).sorted() where !bundleID.hasPrefix("com.apple.") {
      guard let location = newLocation(for: bundleID, matchedFamilies: matchedFamilies) else { continue }
      array.append(location)
      array.append(["location": location, "menuItemLocations": [location], "isAllowed": allowed])
      didChange = true
    }
    return didChange
  }

  /// Key of a new entry; `nil` if the executable's family is already
  /// registered under another path and there is no need to add it.
  private nonisolated static func newLocation(for bundleID: String, matchedFamilies: Set<String>) -> [String: Any]? {
    guard let family = family(of: bundleID) else { return ["bundle": ["_0": bundleID]] }
    return matchedFamilies.contains(family) ? nil : ["adhocBinary": ["_0": ["relative": bundleID]]]
  }

  func setAllowed(_ allowed: Bool, for bundleID: String) throws {
    try setAllowed(allowed, for: Set([bundleID]))
  }

  func setAllowed(_ allowed: Bool, for bundleIDs: Set<String>) throws {
    guard !bundleIDs.isEmpty else { return }
    guard let functions = Functions.shared else { throw MenuBarPreferenceError.unavailable }
    guard
      let value = functions.copy(
        key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container
      )?.takeRetainedValue()
    else { throw MenuBarPreferenceError.preferenceMissing }
    guard let data = value as? Data else { throw MenuBarPreferenceError.invalidData }
    guard var array = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
    else { throw MenuBarPreferenceError.invalidData }

    let didChange = Self.apply(allowed, to: bundleIDs, in: &array)
    guard didChange else { throw MenuBarPreferenceError.applicationNotRegistered }

    let updated = try PropertyListSerialization.data(fromPropertyList: array, format: .binary, options: 0)
    functions.set(key, updated as CFData, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
    guard functions.synchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container) else {
      throw MenuBarPreferenceError.synchronizeFailed
    }
  }
}

enum MenuBarPreferenceError: Error {
  case unavailable
  case preferenceMissing
  case invalidData
  case applicationNotRegistered
  case synchronizeFailed
}
