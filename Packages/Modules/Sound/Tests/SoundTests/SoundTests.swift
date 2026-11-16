// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Foundation
import Testing

@testable import Sound

@Suite("Sound: pure logic")
struct SoundLogicTests {
  @Test("the transport type becomes the device type")
  func classifiesTransport() {
    #expect(AudioDeviceKind(transportType: UInt32(kAudioDeviceTransportTypeBuiltIn)) == .builtIn)
    #expect(AudioDeviceKind(transportType: UInt32(kAudioDeviceTransportTypeBluetooth)) == .bluetooth)
    #expect(AudioDeviceKind(transportType: UInt32(kAudioDeviceTransportTypeBluetoothLE)) == .bluetooth)
    #expect(AudioDeviceKind(transportType: UInt32(kAudioDeviceTransportTypeUSB)) == .usb)
    #expect(AudioDeviceKind(transportType: UInt32(kAudioDeviceTransportTypeAirPlay)) == .airPlay)
    #expect(AudioDeviceKind(transportType: UInt32(kAudioDeviceTransportTypeHDMI)) == .display)
    #expect(AudioDeviceKind(transportType: UInt32(kAudioDeviceTransportTypeDisplayPort)) == .display)
    #expect(AudioDeviceKind(transportType: UInt32(kAudioDeviceTransportTypeVirtual)) == .other)
    #expect(AudioDeviceKind(transportType: 0) == .other)
  }

  @Test("the volume stays between 0 and 1 and is rounded to a percentage")
  func volumeConversion() {
    #expect(VolumeScale.clamped(-0.5) == 0)
    #expect(VolumeScale.clamped(1.7) == 1)
    #expect(VolumeScale.clamped(.nan) == 0)
    #expect(VolumeScale.percent(0.504) == 50)
    #expect(VolumeScale.percent(0.505) == 51)
    #expect(VolumeScale.percent(2) == 100)
    #expect(VolumeScale.scalar(0.25) == 0.25)
  }

  @Test("the block triggers only for Music and only if on")
  func blockDecision() {
    var prefs = SoundPrefs()
    let installed: (String) -> Bool = { $0 == "com.spotify.client" }
    #expect(MusicBlockPolicy.decide(launched: "com.apple.Music", prefs: prefs, isInstalled: installed) == .ignore)
    prefs.blockMusic = true
    #expect(MusicBlockPolicy.decide(launched: "com.apple.Safari", prefs: prefs, isInstalled: installed) == .ignore)
    #expect(MusicBlockPolicy.decide(launched: nil, prefs: prefs, isInstalled: installed) == .ignore)
    #expect(
      MusicBlockPolicy.decide(launched: "com.apple.Music", prefs: prefs, isInstalled: installed)
        == .block(openInstead: nil))
  }

  @Test("the alternative app opens only if it is installed")
  func alternativeApp() {
    var prefs = SoundPrefs()
    prefs.blockMusic = true
    prefs.alternativeBundleID = "com.spotify.client"
    #expect(
      MusicBlockPolicy.decide(launched: "com.apple.Music", prefs: prefs, isInstalled: { _ in true })
        == .block(openInstead: "com.spotify.client"))
    #expect(
      MusicBlockPolicy.decide(launched: "com.apple.Music", prefs: prefs, isInstalled: { _ in false })
        == .block(openInstead: nil))
    prefs.alternativeBundleID = "com.apple.Music"
    #expect(
      MusicBlockPolicy.decide(launched: "com.apple.Music", prefs: prefs, isInstalled: { _ in true })
        == .block(openInstead: nil))
  }

  @Test("old or partial preferences take the defaults")
  func prefsDecoding() throws {
    let empty = try JSONDecoder().decode(SoundPrefs.self, from: Data("{}".utf8))
    #expect(empty == SoundPrefs())
    #expect(empty.includeSystemEffects)
    #expect(!empty.blockMusic)
  }

  @Test("device change: the tap follows the system output, leaves the vanished one, disappears if useless")
  func tapRealignment() {
    let all: Set<String> = ["speakers", "airpods"]
    // Follows the system and the output is the same: stays.
    #expect(
      TapRealignment.decide(outputUID: nil, volume: 0.5, tapUID: "speakers", defaultUID: "speakers", available: all)
        == .keep)
    // Follows the system and the output changed (headphones connected): recreated on the new one.
    #expect(
      TapRealignment.decide(outputUID: nil, volume: 0.5, tapUID: "speakers", defaultUID: "airpods", available: all)
        == .rebuild(uid: "airpods", dropOutput: false))
    // Output chosen for the app still present: untouched.
    #expect(
      TapRealignment.decide(
        outputUID: "airpods", volume: 1, tapUID: "airpods", defaultUID: "speakers", available: all) == .keep)
    // Chosen output vanished, volume reduced: back to the system output.
    #expect(
      TapRealignment.decide(
        outputUID: "airpods", volume: 0.5, tapUID: "airpods", defaultUID: "speakers", available: ["speakers"])
        == .rebuild(uid: "speakers", dropOutput: true))
    // Chosen output vanished, full volume: no tap, the app is not left muted.
    #expect(
      TapRealignment.decide(
        outputUID: "airpods", volume: 1, tapUID: "airpods", defaultUID: "speakers", available: ["speakers"])
        == .remove)
    // No system output: better no tap than a muted app.
    #expect(
      TapRealignment.decide(outputUID: nil, volume: 0.5, tapUID: "speakers", defaultUID: nil, available: [])
        == .remove)
  }
}

@MainActor
@Suite("Sound: model")
struct SoundModelTests {
  @Test("clicking on the device makes it the default, with the effects if the option is on")
  func selectDevice() {
    let backend = FakeBackend()
    let model = SoundModel(backend: backend)
    model.refresh()
    #expect(model.defaultID == 1)
    model.select(backend.devices[1])
    #expect(backend.defaultID == 2)
    #expect(backend.lastIncludedSystem == true)
    #expect(model.defaultID == 2)
    model.includeSystemEffects = false
    model.select(backend.devices[0])
    #expect(backend.lastIncludedSystem == false)
  }

  @Test("raising the volume from mute removes the mute; without adjustable volume it does not write")
  func volumeAndMute() {
    let backend = FakeBackend()
    let model = SoundModel(backend: backend)
    model.refresh()
    model.toggleMute()
    #expect(backend.muted[1] == true)
    model.setVolume(1.4)
    #expect(backend.volumes[1] == 1)
    #expect(backend.muted[1] == false)
    // Volume at zero = mute, like the Mac's keys: at 0 many outputs still play.
    model.setVolume(0)
    #expect(backend.muted[1] == true)
    model.setVolume(0.2)
    #expect(backend.muted[1] == false)
    model.select(backend.devices[1])
    #expect(model.volume == nil)
    model.setVolume(0.3)
    #expect(backend.volumes[2] == nil)
  }

  @Test("list changes re-read the devices, level ones do not")
  func changes() {
    let backend = FakeBackend()
    let model = SoundModel(backend: backend)
    model.refresh()
    backend.devices.removeLast()
    model.handle(.levels)
    #expect(model.devices.count == 2)
    model.handle(.devices)
    #expect(model.devices.count == 1)
  }

  @Test("the per-app slider goes through the controller and forgets at 100%")
  func processVolume() {
    let backend = FakeBackend()
    let mixer = FakeProcessVolume()
    let model = SoundModel(backend: backend, mixer: mixer)
    let app = AudioProcess(id: 42, pid: 101, bundleID: "x", name: "App")
    #expect(model.processVolume(for: app) == 1)
    model.setProcessVolume(0.4, for: app)
    #expect(mixer.volumes[42] == 0.4)
    #expect(model.processVolume(for: app) == 0.4)
    #expect(!model.mixerBlocked)
    model.setProcessVolume(1, for: app)
    #expect(mixer.volumes[42] == nil)
    #expect(model.processVolume(for: app) == 1)
  }

  @Test("tap refusal raises mixerBlocked")
  func processVolumeBlocked() {
    let backend = FakeBackend()
    let mixer = FakeProcessVolume()
    mixer.refuseNext = true
    let model = SoundModel(backend: backend, mixer: mixer)
    let app = AudioProcess(id: 1, pid: 1, bundleID: nil, name: "A")
    model.setProcessVolume(0.3, for: app)
    #expect(model.mixerBlocked)
    #expect(model.processVolume(for: app) == 1)
  }

  @Test("per-app output: setProcessOutput saves the UID, nil goes back to system")
  func processOutput() {
    let backend = FakeBackend()
    let mixer = FakeProcessVolume()
    let model = SoundModel(backend: backend, mixer: mixer)
    let app = AudioProcess(id: 3, pid: 3, bundleID: nil, name: "A")
    #expect(model.processOutputUID(for: app) == nil)
    model.setProcessOutput(backend.devices[1], for: app)
    #expect(mixer.outputs[3] == "b")
    #expect(model.processOutputUID(for: app) == "b")
    model.setProcessOutput(nil, for: app)
    #expect(mixer.outputs[3] == nil)
    #expect(model.processOutputUID(for: app) == nil)
  }

  @Test("output change: per-app volumes stay and taps realign")
  func processVolumesSurviveOutputChange() {
    let backend = FakeBackend()
    let mixer = FakeProcessVolume()
    let model = SoundModel(backend: backend, mixer: mixer)
    let app = AudioProcess(id: 7, pid: 7, bundleID: nil, name: "A")
    model.setProcessVolume(0.5, for: app)
    model.select(backend.devices[1])
    #expect(!mixer.tornDown)
    #expect(mixer.realigned)
    #expect(model.processVolume(for: app) == 0.5)
  }

  @Test("Core Audio's internal aggregates are not outputs")
  func internalAggregatesAreHidden() {
    #expect(CoreAudioBackend.isInternalAggregate(uid: "CADefaultDeviceAggregate-46106-2"))
    #expect(!CoreAudioBackend.isInternalAggregate(uid: "BuiltInSpeakerDevice"))
  }
}

@MainActor
final class FakeBackend: AudioBackend {
  var devices = [
    AudioOutputDevice(id: 1, uid: "a", name: "Altoparlanti", kind: .builtIn),
    AudioOutputDevice(id: 2, uid: "b", name: "Schermo", kind: .display),
  ]
  var defaultID: AudioObjectID? = 1
  var lastIncludedSystem: Bool?
  var volumes: [AudioObjectID: Double] = [1: 0.5]
  var muted: [AudioObjectID: Bool] = [1: false]

  func outputDevices() -> [AudioOutputDevice] { devices }
  func defaultOutputID() -> AudioObjectID? { defaultID }
  func setDefaultOutput(_ id: AudioObjectID, includingSystemEffects: Bool) -> Bool {
    defaultID = id
    lastIncludedSystem = includingSystemEffects
    return true
  }
  func volume(of id: AudioObjectID) -> Double? { volumes[id] }
  func setVolume(_ value: Double, of id: AudioObjectID) { volumes[id] = value }
  func isMuted(_ id: AudioObjectID) -> Bool? { muted[id] }
  func setMuted(_ muted: Bool, of id: AudioObjectID) { self.muted[id] = muted }
  func observe(_ onChange: @escaping @MainActor (AudioChange) -> Void) -> @MainActor () -> Void { {} }
  var runningProcesses: [AudioProcess] = []
  func runningAudioProcesses(keeping: Set<AudioObjectID>) -> [AudioProcess] { runningProcesses }
}

@MainActor
final class FakeProcessVolume: ProcessVolumeController {
  var volumes: [AudioObjectID: Double] = [:]
  var outputs: [AudioObjectID: String] = [:]
  var refuseNext = false
  var tornDown = false
  var realigned = false

  func devicesChanged(availableUIDs: Set<String>) { realigned = true }

  func volume(for processID: AudioObjectID) -> Double { volumes[processID] ?? 1 }
  func outputUID(for processID: AudioObjectID) -> String? { outputs[processID] }

  @discardableResult
  func setVolume(_ value: Double, for processID: AudioObjectID) -> Bool {
    if refuseNext {
      refuseNext = false
      return false
    }
    if value >= 0.999 {
      volumes.removeValue(forKey: processID)
    } else {
      volumes[processID] = value
    }
    return true
  }

  @discardableResult
  func setOutputUID(_ uid: String?, for processID: AudioObjectID) -> Bool {
    if refuseNext {
      refuseNext = false
      return false
    }
    if let uid {
      outputs[processID] = uid
    } else {
      outputs.removeValue(forKey: processID)
    }
    return true
  }

  func tearDown() {
    tornDown = true
    volumes.removeAll()
    outputs.removeAll()
  }
}

@Suite("Sound: app names in the mixer")
struct AudioProcessNameTests {
  @Test("Chrome's service process is shown as Chrome")
  func chromeHelper() {
    let helper = URL(
      fileURLWithPath: "/Applications/Google Chrome.app/Contents/Frameworks/"
        + "Google Chrome Framework.framework/Helpers/Google Chrome Helper.app")
    #expect(CoreAudioProcessList.owningApp(of: helper)?.path == "/Applications/Google Chrome.app")
  }

  @Test("a normal app has no container")
  func plainApp() {
    #expect(CoreAudioProcessList.owningApp(of: URL(fileURLWithPath: "/System/Applications/Music.app")) == nil)
  }
}
