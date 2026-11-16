// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import Darwin
import DesignSystem
import ModuleKit
import SwiftUI

struct MenuBarProcess: Sendable {
  let bundleID: String
  let processID: pid_t
  let bundleURL: URL?
  let displayName: String?
}

/// Status items can belong to LaunchAgents, not to an app registered in
/// NSWorkspace (for example PaperCut Print Deploy). We include them only during
/// the page's explicit refresh, without polling.
enum LaunchAgentProcessDiscovery {
  private struct Agent {
    let bundleID: String
    let rootPath: String
    let displayName: String
  }

  static func runningProcesses() -> [MenuBarProcess] {
    let agents = agentDefinitions()
    guard !agents.isEmpty else { return [] }

    let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard requiredBytes > 0 else { return [] }
    let capacity = Int(requiredBytes) / MemoryLayout<pid_t>.stride + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let bytes = pids.withUnsafeMutableBytes { buffer in
      proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard bytes > 0 else { return [] }

    let count = min(Int(bytes) / MemoryLayout<pid_t>.stride, pids.count)
    return pids[..<count].compactMap { pid in
      guard pid > 0, let path = executablePath(for: pid),
        let agent = agents.first(where: { path.hasPrefix($0.rootPath + "/") })
      else { return nil }
      // macOS registers these processes by executable URL (`adhocBinary`).
      return MenuBarProcess(
        bundleID: URL(fileURLWithPath: path).absoluteString,
        processID: pid,
        bundleURL: nil,
        displayName: agent.displayName
      )
    }
  }

  private static func agentDefinitions() -> [Agent] {
    let fileManager = FileManager.default
    let directories = [
      "/Library/LaunchAgents", "/Library/LaunchDaemons",
      NSHomeDirectory() + "/Library/LaunchAgents",
      NSHomeDirectory() + "/Library/LaunchDaemons",
    ]
    var agents = [Agent]()
    for directory in directories {
      guard let filenames = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
      for filename in filenames where filename.hasSuffix(".plist") {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        guard
          let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let label = plist["Label"] as? String,
          !label.hasPrefix("com.apple."),
          let arguments = plist["ProgramArguments"] as? [String],
          let executable = arguments.first,
          executable.hasPrefix("/")
        else { continue }
        let root = URL(fileURLWithPath: executable).deletingLastPathComponent().standardizedFileURL.path
        agents.append(
          Agent(
            bundleID: label,
            rootPath: root,
            displayName: URL(fileURLWithPath: root).lastPathComponent
          ))
      }
    }
    return agents.sorted { $0.rootPath.count > $1.rootPath.count }
  }

  private static func executablePath(for processID: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = buffer.withUnsafeMutableBufferPointer { pointer in
      proc_pidpath(processID, pointer.baseAddress, UInt32(pointer.count))
    }
    guard length > 0 else { return nil }
    let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(bytes: pathBytes, encoding: .utf8)
  }
}

enum MenuBarItemDiscovery {
  private static let queue = DispatchQueue(label: "dev.local.tsukumo.menu-bar-discovery", qos: .utility)

  static func bundleIDs(in processes: [MenuBarProcess]) async -> Set<String> {
    await withCheckedContinuation { continuation in
      queue.async {
        var result = Set<String>()
        for process in processes {
          let application = AXUIElementCreateApplication(process.processID)
          AXUIElementSetMessagingTimeout(application, 0.15)
          var extras: CFTypeRef?
          guard
            AXUIElementCopyAttributeValue(
              application, kAXExtrasMenuBarAttribute as CFString, &extras
            ) == .success, let extras, CFGetTypeID(extras) == AXUIElementGetTypeID()
          else {
            continue
          }
          let extrasElement = unsafeDowncast(extras, to: AXUIElement.self)
          // The app's timeout does not pass to child elements.
          AXUIElementSetMessagingTimeout(extrasElement, 0.15)
          var children: CFTypeRef?
          guard
            AXUIElementCopyAttributeValue(
              extrasElement, kAXChildrenAttribute as CFString, &children
            ) == .success, let children, CFGetTypeID(children) == CFArrayGetTypeID()
          else {
            continue
          }
          let childArray = unsafeDowncast(children, to: CFArray.self)
          if CFArrayGetCount(childArray) > 0 {
            result.insert(process.bundleID)
          }
        }
        continuation.resume(returning: result)
      }
    }
  }
}
