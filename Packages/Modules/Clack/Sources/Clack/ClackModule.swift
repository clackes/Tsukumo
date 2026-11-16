// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import AppKit
import CoreGraphics
import DesignSystem
import ModuleKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class ClackModel {
  public fileprivate(set) var pack: ClackPack = .linear
  /// Name of the file loaded by the user, if any.
  public fileprivate(set) var customSoundName: String?
  public fileprivate(set) var usesCustomSound = false
  public fileprivate(set) var customSoundError: String?
  /// Imported Mechvibes packs and the one in use, if any.
  public fileprivate(set) var importedPacks: [ImportedPack] = []
  public fileprivate(set) var mechvibesID: String?
  public fileprivate(set) var packError: String?
  public fileprivate(set) var volume: Double = 0.6
  public fileprivate(set) var playsKeyUp = true
  /// `true` if the system has not granted the tap (permission not yet effective).
  public fileprivate(set) var tapUnavailable = false
}

/// Mechanical keyboard sounds. At rest: one subscription to the shared listen tap
/// and no audio engine running; the idle timer exists only while sound is playing.
@MainActor
public final class ClackModule: TsukumoModule {
  public nonisolated static let descriptor = ModuleDescriptor(
    id: "clack",
    nameKey: "Keyboard Sounds",
    symbol: "keyboard.fill",
    tint: .orange,
    permissions: [.inputMonitoring],
    energyClass: .low
  )

  /// Seconds without key presses after which the engine pauses.
  static let idleSeconds: Double = 15

  public private(set) var model: ClackModel?
  private let context: ModuleContext
  private var engine: ClackEngine?
  private var idleTimer: ResourceBag.Token?

  public init(context: ModuleContext) {
    self.context = context
  }

  public func start() async throws {
    let model = ClackModel()
    let id = Self.descriptor.id
    model.pack = context.settings.value(forKey: "pack", moduleID: id) ?? .linear
    model.volume = context.settings.value(forKey: "volume", moduleID: id) ?? 0.6
    model.playsKeyUp = context.settings.value(forKey: "playsKeyUp", moduleID: id) ?? true
    model.customSoundName = context.settings.value(forKey: "customSoundName", moduleID: id)
    if model.customSoundName != nil, !FileManager.default.fileExists(atPath: Self.customSoundURL.path) {
      model.customSoundName = nil
    }
    let wantsCustom: Bool = context.settings.value(forKey: "usesCustomSound", moduleID: id) ?? false
    model.usesCustomSound = wantsCustom && model.customSoundName != nil
    let imported: [ImportedPack] = context.settings.value(forKey: "importedPacks", moduleID: id) ?? []
    model.importedPacks = imported.filter {
      FileManager.default.fileExists(atPath: MechvibesStore.directory(for: $0.id).path)
    }
    let selected: String? = context.settings.value(forKey: "mechvibesID", moduleID: id)
    model.mechvibesID = model.importedPacks.contains { $0.id == selected } ? selected : nil
    self.model = model

    let engine = ClackEngine { [weak self] running in
      Task { @MainActor in self?.engineRunningChanged(running) }
    }
    self.engine = engine
    applyConfiguration()
    context.resources.add(.other) { engine.shutdown() }
    // Output device change (headphones, AirPlay): the engine restarts at the next key press.
    context.resources.addObserver(.AVAudioEngineConfigurationChange) { [weak engine] in
      engine?.configurationChanged()
    }

    let mask = CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << CGEventType.keyUp.rawValue
    do {
      let subscription = try context.inputTaps.subscribe(.listen, mask: mask) { [engine] type, event in
        // Auto-repeat from a held key does not play.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return event }
        engine.keyEvent(
          keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
          isDown: type == .keyDown,
          timestamp: event.timestamp
        )
        return event
      }
      context.resources.addInputTap(subscription)
    } catch {
      model.tapUnavailable = true
      throw error
    }
  }

  public func stop() async {
    idleTimer = nil
    engine = nil
    model = nil
  }

  public var settings: AnyView {
    AnyView(ClackSettingsView(model: model, module: self))
  }

  // MARK: Settings

  func setPack(_ pack: ClackPack) {
    model?.pack = pack
    try? context.settings.set(pack, forKey: "pack", moduleID: Self.descriptor.id)
    selectMechvibes(nil, apply: false)
    setUsesCustomSound(false)
  }

  func setUsesCustomSound(_ enabled: Bool) {
    guard let model else { return }
    model.usesCustomSound = enabled && model.customSoundName != nil
    if model.usesCustomSound { selectMechvibes(nil, apply: false) }
    try? context.settings.set(model.usesCustomSound, forKey: "usesCustomSound", moduleID: Self.descriptor.id)
    applyConfiguration()
  }

  /// Uses an imported Mechvibes pack (`nil` goes back to the built-in sounds).
  func selectMechvibes(_ id: String?, apply: Bool = true) {
    guard let model else { return }
    model.mechvibesID = model.importedPacks.contains { $0.id == id } ? id : nil
    try? context.settings.set(model.mechvibesID, forKey: "mechvibesID", moduleID: Self.descriptor.id)
    guard apply else { return }
    if model.mechvibesID != nil {
      model.usesCustomSound = false
      try? context.settings.set(false, forKey: "usesCustomSound", moduleID: Self.descriptor.id)
    }
    applyConfiguration()
  }

  /// Imports a Mechvibes pack from a folder (or its `config.json`) and selects it.
  func importMechvibesPack(from url: URL) {
    guard let model else { return }
    do {
      let pack = try MechvibesStore.importPack(from: url)
      model.importedPacks.append(pack)
      model.packError = nil
      saveImportedPacks()
      selectMechvibes(pack.id)
    } catch MechvibesError.missingFile(let name), MechvibesError.unreadableAudio(let name) {
      model.packError = String(localized: "The pack is incomplete: \(name) is missing or unreadable.")
    } catch MechvibesError.tooLarge {
      model.packError = String(localized: "The pack is too large.")
    } catch {
      model.packError = String(localized: "Not a Mechvibes pack: a folder with config.json is required.")
    }
  }

  func removeMechvibesPack(_ id: String) {
    guard let model else { return }
    if model.mechvibesID == id { selectMechvibes(nil) }
    model.importedPacks.removeAll { $0.id == id }
    saveImportedPacks()
    MechvibesStore.remove(id: id)
  }

  private func saveImportedPacks() {
    try? context.settings.set(model?.importedPacks, forKey: "importedPacks", moduleID: Self.descriptor.id)
  }

  /// Copy of the file chosen by the user, inside the app's Application Support.
  static var customSoundURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Tsukumo/Clack/custom-sound", isDirectory: false)
  }

  /// Imports an audio file: validates it, copies it and uses it as the key sound.
  func importCustomSound(from url: URL) {
    guard let model else { return }
    guard ClackEngine.buffer(fromFile: url) != nil else {
      model.customSoundError = String(localized: "This audio file can't be read.")
      return
    }
    let destination = Self.customSoundURL
    do {
      let manager = FileManager.default
      try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
      try manager.copyItem(at: url, to: destination)
    } catch {
      model.customSoundError = String(localized: "The file couldn't be saved.")
      return
    }
    model.customSoundError = nil
    model.customSoundName = url.lastPathComponent
    try? context.settings.set(url.lastPathComponent, forKey: "customSoundName", moduleID: Self.descriptor.id)
    // Same path as before but new content: forces a re-read.
    engine?.configure(source: .pack(model.pack), volume: Float(model.volume), playsKeyUp: model.playsKeyUp)
    setUsesCustomSound(true)
  }

  func setVolume(_ volume: Double) {
    model?.volume = min(1, max(0, volume))
    try? context.settings.set(model?.volume, forKey: "volume", moduleID: Self.descriptor.id)
    applyConfiguration()
  }

  func setPlaysKeyUp(_ enabled: Bool) {
    model?.playsKeyUp = enabled
    try? context.settings.set(enabled, forKey: "playsKeyUp", moduleID: Self.descriptor.id)
    applyConfiguration()
  }

  /// Plays a test key from Settings.
  func preview() {
    engine?.keyEvent(keyCode: 49, isDown: true, timestamp: 0)
  }

  private func applyConfiguration() {
    guard let model else { return }
    let source: ClackSource =
      if let id = model.mechvibesID {
        .mechvibes(MechvibesStore.directory(for: id))
      } else if model.usesCustomSound {
        .file(Self.customSoundURL)
      } else {
        .pack(model.pack)
      }
    engine?.configure(source: source, volume: Float(model.volume), playsKeyUp: model.playsKeyUp)
  }

  // MARK: Engine lifecycle

  /// The inactivity check exists only while the engine is on.
  private func engineRunningChanged(_ running: Bool) {
    if let idleTimer { context.resources.cancel(idleTimer) }
    idleTimer = nil
    guard running, let engine else { return }
    idleTimer = context.resources.addTimer(every: .seconds(5), tolerance: .seconds(2)) { [weak engine] in
      engine?.pauseIfIdle(after: Self.idleSeconds)
    }
  }
}

@MainActor
struct ClackSettingsView: View {
  static let customTag = "custom"
  static let mechvibesPrefix = "mechvibes:"

  let model: ClackModel?
  let module: ClackModule
  @State private var confirmsRemoval = false

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = String(localized: "Choose a short sound: it plays on every key press.")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    module.importCustomSound(from: url)
  }

  private func choosePack() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.message = String(localized: "Choose a Mechvibes pack folder (the one with config.json).")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    module.importMechvibesPack(from: url)
  }

  private var selection: Binding<String> {
    Binding(
      get: {
        if let id = model?.mechvibesID { return ClackSettingsView.mechvibesPrefix + id }
        return model?.usesCustomSound == true ? ClackSettingsView.customTag : (model?.pack ?? .linear).rawValue
      },
      set: { tag in
        if tag.hasPrefix(ClackSettingsView.mechvibesPrefix) {
          module.selectMechvibes(String(tag.dropFirst(ClackSettingsView.mechvibesPrefix.count)))
        } else if tag == ClackSettingsView.customTag {
          module.setUsesCustomSound(true)
        } else if let pack = ClackPack(rawValue: tag) {
          module.setPack(pack)
        }
      }
    )
  }

  var body: some View {
    Form {
      Section("Key Sounds") {
        Picker(
          "Switch type",
          selection: selection
        ) {
          ForEach(ClackPack.allCases, id: \.self) { pack in
            Text(pack.title).tag(pack.rawValue)
          }
          if let name = model?.customSoundName {
            Divider()
            Text(name).tag(ClackSettingsView.customTag)
          }
          if let packs = model?.importedPacks, !packs.isEmpty {
            Divider()
            ForEach(packs) { pack in
              Text(verbatim: pack.name).tag(ClackSettingsView.mechvibesPrefix + pack.id)
            }
          }
        }
        LabeledContent("Mechvibes pack") {
          HStack {
            if let id = model?.mechvibesID {
              Button("Remove…") { confirmsRemoval = true }
                .confirmationDialog(
                  "Remove the imported pack?", isPresented: $confirmsRemoval
                ) {
                  Button("Remove", role: .destructive) { module.removeMechvibesPack(id) }
                } message: {
                  Text("Tsukumo deletes the pack; you need to import it again to use it.")
                }
            }
            Button("Import a pack…") { choosePack() }
          }
        }
        if let error = model?.packError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        LabeledContent("Custom sound") {
          Button("Load a file…") { chooseFile() }
        }
        if let error = model?.customSoundError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        Slider(
          value: Binding(get: { model?.volume ?? 0 }, set: { module.setVolume($0) }),
          in: 0...1
        ) {
          Text("Volume")
        }
        Toggle(
          "Play a sound on key release",
          isOn: Binding(get: { model?.playsKeyUp ?? false }, set: { module.setPlaysKeyUp($0) })
        )
        Button("Test") { module.preview() }
      }
      Section {
        Text(
          "A custom sound is trimmed to a second and a half. "
            + "A Mechvibes pack plays a different sound for each key, on key press only. "
            + "The sound mutes itself in password fields. "
            + "After 15 seconds without keystrokes the audio pauses to save energy."
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text("Keyboard Sounds"))
    .disabled(model == nil)
  }
}

extension ClackPack {
  var title: LocalizedStringKey {
    switch self {
    case .linear: "Linear"
    case .tactile: "Tactile"
    case .clicky: "Clicky"
    case .deep: "Deep"
    case .muffled: "Muted"
    case .typewriter: "Typewriter"
    case .legno: "Wood"
    case .bolla: "Bubble"
    case .vetro: "Glass"
    case .retro: "8‑bit"
    }
  }
}
