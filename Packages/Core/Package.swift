// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
  name: "Core",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ModuleKit", targets: ["ModuleKit"])
  ],
  targets: [
    .target(name: "ModuleKit"),
    .testTarget(name: "ModuleKitTests", dependencies: ["ModuleKit"]),
  ],
  swiftLanguageModes: [.v6]
)
