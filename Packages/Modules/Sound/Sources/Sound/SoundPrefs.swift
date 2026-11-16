// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Sound preferences. Missing keys take the default value.
struct SoundPrefs: Codable, Equatable, Sendable {
  /// The output change also applies to notifications and system sounds.
  var includeSystemEffects = true
  /// Closes Music as soon as it launches.
  var blockMusic = false
  /// App to open instead of Music (bundle id), if installed.
  var alternativeBundleID: String?

  init() {}

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    includeSystemEffects = try values.decodeIfPresent(Bool.self, forKey: .includeSystemEffects) ?? true
    blockMusic = try values.decodeIfPresent(Bool.self, forKey: .blockMusic) ?? false
    alternativeBundleID = try values.decodeIfPresent(String.self, forKey: .alternativeBundleID)
  }
}
