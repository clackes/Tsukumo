// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
  name: "DesignSystem",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DesignSystem", targets: ["DesignSystem"])
  ],
  dependencies: [
    .package(path: "../Core")
  ],
  targets: [
    .target(name: "DesignSystem", dependencies: [.product(name: "ModuleKit", package: "Core")]),
    .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
  ],
  swiftLanguageModes: [.v6]
)
