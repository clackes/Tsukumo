// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// A `dlopen` handle kept alive for the whole session, shared between the
/// wrappers of the same private framework (DESIGN.md §4.1). Meant as the
/// single point for auditing private API use: everything that resolves
/// a symbol goes through here.
///
/// It does not try to close the framework: on macOS they are not unloaded, and the resolved
/// symbol pointers stay valid for the whole life of the process.
public final class FrameworkHandle: @unchecked Sendable {
  public let path: String
  /// `nil` if the framework does not exist on this macOS version.
  public let handle: UnsafeMutableRawPointer?

  public init(path: String) {
    self.path = path
    self.handle = dlopen(path, RTLD_LAZY)
  }

  /// Resolves a typed symbol. `nil` if missing.
  public func symbol<Function>(_ name: String, as type: Function.Type) -> Function? {
    guard let handle else { return nil }
    return dlsym(handle, name).map { unsafeBitCast($0, to: type) }
  }

  public var isAvailable: Bool { handle != nil }
}
