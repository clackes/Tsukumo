// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
  name: "MenuBar",
  platforms: [.macOS(.v26)],
  products: [.library(name: "MenuBar", targets: ["MenuBar"])],
  dependencies: [
    .package(path: "../../Core"),
    .package(path: "../../DesignSystem"),
  ],
  targets: [
    .target(
      name: "MenuBar",
      dependencies: [
        .product(name: "ModuleKit", package: "Core"),
        .product(name: "DesignSystem", package: "DesignSystem"),
      ]
    ),
    .testTarget(name: "MenuBarTests", dependencies: ["MenuBar"]),
  ],
  swiftLanguageModes: [.v6]
)
