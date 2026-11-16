// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
  name: "Sound",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Sound", targets: ["Sound"])
  ],
  dependencies: [
    .package(path: "../../Core"),
    .package(path: "../../DesignSystem"),
  ],
  targets: [
    .target(
      name: "Sound",
      dependencies: [
        .product(name: "ModuleKit", package: "Core"),
        .product(name: "DesignSystem", package: "DesignSystem"),
      ]
    ),
    .testTarget(name: "SoundTests", dependencies: ["Sound"]),
  ],
  swiftLanguageModes: [.v6]
)
