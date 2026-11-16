// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
  name: "Island",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Island", targets: ["Island"])
  ],
  dependencies: [
    .package(path: "../../Core"),
    .package(path: "../../DesignSystem"),
    .package(path: "../../Bridges"),
  ],
  targets: [
    .target(
      name: "Island",
      dependencies: [
        .product(name: "ModuleKit", package: "Core"),
        .product(name: "DesignSystem", package: "DesignSystem"),
        .product(name: "PrivateBridges", package: "Bridges"),
      ]
    ),
    .testTarget(name: "IslandTests", dependencies: ["Island"]),
  ],
  swiftLanguageModes: [.v6]
)
