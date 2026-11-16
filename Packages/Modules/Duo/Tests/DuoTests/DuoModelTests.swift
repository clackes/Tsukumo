// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Testing

@testable import Duo

@MainActor
@Suite("Duo: current angle in Settings")
struct DuoModelTests {
  @Test("the angle rounds to the degree and changes only when the degree changes")
  func reportRounds() {
    let model = DuoModel()
    #expect(model.currentAngle == nil)
    model.report(97.4)
    #expect(model.currentAngle == 97)
    model.report(97.6)
    #expect(model.currentAngle == 98)
    model.report(98.2)
    #expect(model.currentAngle == 98)
  }
}
