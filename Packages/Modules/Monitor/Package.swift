// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
  name: "Monitor",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Monitor", targets: ["Monitor"])
  ],
  dependencies: [
    .package(path: "../../Core"),
    .package(path: "../../DesignSystem"),
  ],
  targets: [
    .target(
      name: "Monitor",
      dependencies: [
        .product(name: "ModuleKit", package: "Core"),
        .product(name: "DesignSystem", package: "DesignSystem"),
      ]
    ),
    .testTarget(name: "MonitorTests", dependencies: ["Monitor"]),
  ],
  swiftLanguageModes: [.v6]
)
