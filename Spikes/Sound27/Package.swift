// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
  name: "Sound27Spike",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(name: "Sound27Spike"),
  ]
)
