// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Testing

@testable import Sound

@Suite("Sound: silence at zero volume")
@MainActor
struct SilenceAtZeroTests {
  @Test("volume brought to zero from outside turns on mute, and raising it removes it")
  func externalZeroMutes() {
    let backend = FakeBackend()
    let model = SoundModel(backend: backend)
    model.refresh()
    #expect(backend.muted[1] == false)

    backend.volumes[1] = 0
    model.handle(.levels)
    #expect(backend.muted[1] == true)

    backend.volumes[1] = 0.3
    model.handle(.levels)
    #expect(backend.muted[1] == false)
  }

  @Test("a mute chosen by the user at high volume stays")
  func userMuteStays() {
    let backend = FakeBackend()
    let model = SoundModel(backend: backend)
    model.refresh()
    model.toggleMute()
    #expect(backend.muted[1] == true)
    backend.volumes[1] = 0.6
    model.handle(.levels)
    #expect(backend.muted[1] == true)
  }

  @Test("already at zero at start: mute immediately")
  func zeroAtStart() {
    let backend = FakeBackend()
    backend.volumes[1] = 0
    let model = SoundModel(backend: backend)
    model.refresh()
    #expect(backend.muted[1] == true)
  }
}
