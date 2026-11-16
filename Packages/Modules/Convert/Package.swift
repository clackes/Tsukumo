// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
  name: "Convert",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Convert", targets: ["Convert"]),
    .library(name: "ConverterKit", targets: ["ConverterKit"]),
  ],
  dependencies: [
    .package(path: "../../Core"),
    .package(path: "../../DesignSystem"),
  ],
  targets: [
    .target(
      name: "Convert",
      dependencies: [
        "ConverterKit",
        .product(name: "ModuleKit", package: "Core"),
        .product(name: "DesignSystem", package: "DesignSystem"),
      ]
    ),
    .target(name: "ConverterKit"),
    .testTarget(name: "ConvertTests", dependencies: ["Convert", "ConverterKit"]),
  ],
  swiftLanguageModes: [.v6]
)
