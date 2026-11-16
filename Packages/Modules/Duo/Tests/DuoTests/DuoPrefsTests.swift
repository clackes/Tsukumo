// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import Duo

@Suite("Duo: preferences")
struct DuoPrefsTests {
  @Test("preferences saved before the new keys remain valid")
  func oldPrefsDecode() throws {
    let old = Data(#"{"blur":0.3,"motion":0,"perspective":1.2,"shadow":0.35,"startAngle":60}"#.utf8)
    let prefs = try JSONDecoder().decode(DuoPrefs.self, from: old)
    #expect(prefs.blur == 0.3)
    #expect(prefs.startAngle == 60)
    #expect(prefs.deadZone == 8)
    #expect(prefs.activationAngle == 140)
  }

  @Test("the dead zone delays the start of the fold")
  func deadZoneDelaysFold() {
    var tight = LidModel(angle: 110)
    tight.dynamic = true
    tight.deadZone = 0
    var loose = LidModel(angle: 110)
    loose.dynamic = true
    loose.deadZone = 20
    for _ in 0..<30 {
      tight.step(target: 100, dt: 1.0 / 60)
      loose.step(target: 100, dt: 1.0 / 60)
    }
    #expect(tight.tilt > 0)
    #expect(loose.tilt == 0)
  }
}
