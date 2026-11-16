// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Fixed-capacity ring buffer for sparklines: the oldest element
/// drops out when capacity is exceeded. It fills only when a sample arrives,
/// with no timers of its own.
struct RingBuffer<Element: Sendable>: Sendable {
  let capacity: Int
  private(set) var elements: [Element] = []

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
    elements.reserveCapacity(capacity)
  }

  var count: Int { elements.count }
  var isEmpty: Bool { elements.isEmpty }
  var last: Element? { elements.last }

  mutating func append(_ element: Element) {
    if elements.count == capacity { elements.removeFirst() }
    elements.append(element)
  }

  mutating func removeAll() {
    elements.removeAll(keepingCapacity: true)
  }
}

/// Received/sent pair of a network sample (bytes per second).
struct NetworkRate: Sendable, Equatable {
  var received: Double
  var sent: Double
}

/// Severity of a ring: decides the color. Green below 60 %, yellow below
/// 85 %, red above; for the battery it is the opposite (what remains counts).
enum GaugeLevel: Equatable {
  case normal
  case warning
  case critical

  static let warningUsage: Double = 60
  static let criticalUsage: Double = 85
  /// Battery: yellow below 40 %, red below 15 %.
  static let warningBattery: Int = 40
  static let criticalBattery: Int = 15

  /// Usage as a percentage (CPU, memory, disk).
  init(usage percent: Double) {
    if percent >= Self.criticalUsage {
      self = .critical
    } else if percent >= Self.warningUsage {
      self = .warning
    } else {
      self = .normal
    }
  }

  /// Remaining charge: with the power adapter connected it is never an alarm.
  init(batteryPercent percent: Int, isPluggedIn: Bool = false) {
    if isPluggedIn || percent >= Self.warningBattery {
      self = .normal
    } else if percent >= Self.criticalBattery {
      self = .warning
    } else {
      self = .critical
    }
  }

  var color: Color {
    switch self {
    case .normal: .green
    case .warning: .yellow
    case .critical: .red
    }
  }
}
