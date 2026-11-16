// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
  name: "Bridges",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "PrivateBridges", targets: ["PrivateBridges"])
  ],
  targets: [
    .target(name: "PrivateBridges"),
    .testTarget(name: "PrivateBridgesTests", dependencies: ["PrivateBridges"]),
  ],
  swiftLanguageModes: [.v6]
)
