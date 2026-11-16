// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

// MARK: - Engine

/// Metadata categories that can be removed.
enum MetadataCategory: String, CaseIterable, Hashable, Sendable {
  case gps, camera, iptc, all

  var title: LocalizedStringKey {
    switch self {
    case .gps: "GPS Location"
    case .camera: "Camera / EXIF"
    case .iptc: "IPTC / Author"
    case .all: "All"
    }
  }

  /// The real categories (without "All").
  static let specific: [MetadataCategory] = [.gps, .camera, .iptc]
}

/// A readable entry: key and value already formatted.
struct MetadataEntry: Hashable, Sendable {
  let key: String
  let value: String
}

/// A group of entries with a title and the removal category it belongs to (if any).
struct MetadataGroup: Identifiable, Hashable, Sendable {
  let title: String
  let category: MetadataCategory?
  let entries: [MetadataEntry]

  var id: String { title }
}

/// Reading, filtering and removing metadata with ImageIO.
enum ImageMetadata {
  // ImageIO dictionary keys for each group.
  private static let gpsKey = kCGImagePropertyGPSDictionary as String
  private static let exifKey = kCGImagePropertyExifDictionary as String
  private static let tiffKey = kCGImagePropertyTIFFDictionary as String
  private static let iptcKey = kCGImagePropertyIPTCDictionary as String
  private static let auxKey = kCGImagePropertyExifAuxDictionary as String

  /// Structural entries that are not "personal" metadata: they remain even after removal.
  private static let structuralExif: Set<String> = [
    "PixelXDimension", "PixelYDimension", "ColorSpace", "ComponentsConfiguration", "ExifVersion", "FlashPixVersion",
  ]
  private static let structuralTIFF: Set<String> = [
    "Orientation", "XResolution", "YResolution", "ResolutionUnit", "Compression", "PhotometricInterpretation",
  ]

  // MARK: Reading

  static func properties(of url: URL) -> [String: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let found = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    else { return [:] }
    return found
  }

  /// Readable groups, in order: image, camera, EXIF, GPS, IPTC, other.
  static func groups(of url: URL) -> [MetadataGroup] {
    groups(from: properties(of: url))
  }

  static func groups(from properties: [String: Any]) -> [MetadataGroup] {
    var result: [MetadataGroup] = []
    func add(_ title: String, _ category: MetadataCategory?, _ values: [String: Any]) {
      let entries = values.compactMap { key, value -> MetadataEntry? in
        guard let text = format(value) else { return nil }
        return MetadataEntry(key: humanize(key), value: text)
      }.sorted { $0.key < $1.key }
      if !entries.isEmpty { result.append(MetadataGroup(title: title, category: category, entries: entries)) }
    }

    let root = properties.filter { !($0.value is [String: Any]) }
    add(String(localized: "Image"), nil, root)

    var camera = (properties[tiffKey] as? [String: Any]) ?? [:]
    for (key, value) in (properties[auxKey] as? [String: Any]) ?? [:] { camera[key] = value }
    for (key, value) in properties where key.hasPrefix("{Maker") {
      for (inner, innerValue) in (value as? [String: Any]) ?? [:] { camera["\(key) \(inner)"] = innerValue }
    }
    add(String(localized: "Camera"), .camera, camera)
    add("EXIF", .camera, (properties[exifKey] as? [String: Any]) ?? [:])
    add(String(localized: "GPS Location"), .gps, (properties[gpsKey] as? [String: Any]) ?? [:])
    add(String(localized: "IPTC / Author"), .iptc, (properties[iptcKey] as? [String: Any]) ?? [:])

    let known: Set<String> = [tiffKey, auxKey, exifKey, gpsKey, iptcKey]
    var other: [String: Any] = [:]
    for (key, value) in properties where !known.contains(key) && !key.hasPrefix("{Maker") {
      guard let inner = value as? [String: Any] else { continue }
      for (innerKey, innerValue) in inner { other["\(key) \(innerKey)"] = innerValue }
    }
    add(String(localized: "Other"), nil, other)
    return result
  }

  /// How many entries belong to a category (to show which switches make sense).
  static func count(of category: MetadataCategory, in groups: [MetadataGroup]) -> Int {
    switch category {
    case .all: groups.filter { $0.category != nil }.reduce(0) { $0 + $1.entries.count }
    default: groups.filter { $0.category == category }.reduce(0) { $0 + $1.entries.count }
    }
  }

  /// "FNumber" becomes "F Number": spaces before capitals that follow a lowercase letter.
  static func humanize(_ key: String) -> String {
    var output = ""
    var previous: Character?
    for character in key {
      if let previous, character.isUppercase, previous.isLowercase { output.append(" ") }
      output.append(character)
      previous = character
    }
    return output
  }

  static func format(_ value: Any) -> String? {
    switch value {
    case let text as String:
      return text.isEmpty ? nil : text
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue ? String(localized: "Yes") : String(localized: "No")
      }
      let double = number.doubleValue
      if double == double.rounded() && abs(double) < 1e15 { return String(Int64(double)) }
      return double.formatted(.number.precision(.fractionLength(0...4)))
    case let array as [Any]:
      let parts = array.compactMap { format($0) }
      return parts.isEmpty ? nil : parts.joined(separator: ", ")
    case let data as Data:
      return String(localized: "\(data.count) bytes")
    case is [String: Any]:
      return nil
    default:
      return "\(value)"
    }
  }

  // MARK: Removal

  /// XMP/EXIF tag prefixes belonging to each category.
  private static func shouldRemove(prefix: String, name: String, categories: Set<MetadataCategory>) -> Bool {
    if categories.contains(.all) { return true }
    if categories.contains(.gps), prefix == "exif", name.hasPrefix("GPS") { return true }
    if categories.contains(.camera) {
      if ["exif", "exifEX", "tiff", "aux", "xmp", "crs"].contains(prefix)
        && !(prefix == "exif" && name.hasPrefix("GPS"))
      {
        return true
      }
      if prefix == "photoshop", name == "DateCreated" { return true }
    }
    if categories.contains(.iptc),
      ["dc", "photoshop", "Iptc4xmpCore", "Iptc4xmpExt", "iio", "xmpRights", "plus"].contains(prefix)
    {
      return true
    }
    return false
  }

  /// Is anything left of the categories to remove? (check after the copy without re-encoding)
  static func hasResidue(_ properties: [String: Any], categories: Set<MetadataCategory>) -> Bool {
    let wantsAll = categories.contains(.all)
    func filled(_ key: String, ignoring ignored: Set<String> = []) -> Bool {
      guard let dictionary = properties[key] as? [String: Any] else { return false }
      return !Set(dictionary.keys).subtracting(ignored).isEmpty
    }
    if wantsAll || categories.contains(.gps), filled(gpsKey) { return true }
    if wantsAll || categories.contains(.iptc), filled(iptcKey) { return true }
    if wantsAll || categories.contains(.camera) {
      if filled(exifKey, ignoring: structuralExif) || filled(tiffKey, ignoring: structuralTIFF) || filled(auxKey) {
        return true
      }
      if properties.keys.contains(where: { $0.hasPrefix("{Maker") }) { return true }
    }
    return false
  }

  /// Properties to rewrite in a re-encode: everything that is not being removed.
  /// Orientation and dimensions are excluded (the pixels are already oriented and the encoder recomputes the sizes).
  static func carriedProperties(from properties: [String: Any], removing categories: Set<MetadataCategory>)
    -> [CFString: Any]
  {
    let wantsAll = categories.contains(.all)
    var result: [CFString: Any] = [:]
    if wantsAll { return result }
    if !categories.contains(.gps), let gps = properties[gpsKey] { result[kCGImagePropertyGPSDictionary] = gps }
    if !categories.contains(.iptc), let iptc = properties[iptcKey] { result[kCGImagePropertyIPTCDictionary] = iptc }
    if !categories.contains(.camera) {
      if var exif = properties[exifKey] as? [String: Any] {
        for key in structuralExif { exif[key] = nil }
        result[kCGImagePropertyExifDictionary] = exif
      }
      if var tiff = properties[tiffKey] as? [String: Any] {
        for key in structuralTIFF { tiff[key] = nil }
        result[kCGImagePropertyTIFFDictionary] = tiff
      }
      if let aux = properties[auxKey] { result[kCGImagePropertyExifAuxDictionary] = aux }
    }
    return result
  }

  /// Writes a copy without the chosen categories. First tries without re-encoding the pixels
  /// (`CGImageDestinationCopyImageSource`); if traces remain or the format does not allow it, re-encodes
  /// at maximum quality carrying over only the metadata that remains.
  @discardableResult
  static func strip(_ url: URL, removing categories: Set<MetadataCategory>, suffix: String = "-no-metadata") throws
    -> URL
  {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
      throw ToolImageError.unreadable(url.lastPathComponent)
    }
    let output = OutputNamer.url(for: url, extension: url.pathExtension, suffix: suffix)
    if copyWithoutReencoding(source, type: type, to: output, categories: categories),
      !hasResidue(properties(of: output), categories: categories)
    {
      return output
    }
    try? FileManager.default.removeItem(at: output)

    let image = try ToolImage.load(url)
    let carried = carriedProperties(from: properties(of: url), removing: categories)
    return try ToolImage.save(image, like: url, suffix: suffix, quality: 1.0, properties: carried)
  }

  private static func copyWithoutReencoding(
    _ source: CGImageSource, type: CFString, to output: URL, categories: Set<MetadataCategory>
  ) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { return false }
    var options: [CFString: Any] = [:]
    if categories.contains(.all) {
      options[kCGImageMetadataShouldExcludeGPS] = true
      options[kCGImageMetadataShouldExcludeXMP] = true
    } else {
      if categories.contains(.gps) { options[kCGImageMetadataShouldExcludeGPS] = true }
      guard let found = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
        let metadata = CGImageMetadataCreateMutableCopy(found),
        let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]
      else { return false }
      for tag in tags {
        guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
          let name = CGImageMetadataTagCopyName(tag) as String?,
          shouldRemove(prefix: prefix, name: name, categories: categories)
        else { continue }
        CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
      }
      options[kCGImageDestinationMetadata] = metadata
      options[kCGImageDestinationMergeMetadata] = false
    }
    return CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
  }
}

// MARK: - View

/// Metadata: lists the first file's metadata and writes a copy without the chosen categories.
struct MetadataToolView: View {
  let context: ToolContext

  @State private var groups: [MetadataGroup] = []
  @State private var loaded = false
  @State private var selection: Set<MetadataCategory> = []

  var body: some View {
    VStack(spacing: 0) {
      list
      Divider()
      toggles
      Divider()
      ToolFooter(context: context, canApply: !selection.isEmpty, apply: apply)
    }
    .task {
      guard let first = context.files.first else { return }
      groups = await Task.detached(priority: .userInitiated) { ImageMetadata.groups(of: first) }.value
      loaded = true
    }
  }

  private var list: some View {
    Group {
      if !loaded {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if groups.isEmpty {
        ContentUnavailableView("No Metadata", systemImage: "doc.questionmark")
      } else {
        List {
          ForEach(groups) { group in
            Section(group.title) {
              ForEach(group.entries, id: \.self) { entry in
                HStack(alignment: .firstTextBaseline) {
                  Text(verbatim: entry.key).foregroundStyle(.secondary)
                  Spacer(minLength: 12)
                  Text(verbatim: entry.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                .font(.callout)
              }
            }
          }
        }
        .scrollContentBackground(.hidden)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var toggles: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Remove").font(.subheadline.weight(.semibold))
      ForEach(MetadataCategory.specific, id: \.self) { category in
        categoryToggle(category)
      }
      Toggle(isOn: allBinding) { Text(MetadataCategory.all.title) }
        .disabled(ImageMetadata.count(of: .all, in: groups) == 0)
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
  }

  private func categoryToggle(_ category: MetadataCategory) -> some View {
    let count = ImageMetadata.count(of: category, in: groups)
    return Toggle(
      isOn: Binding(
        get: { selection.contains(.all) || selection.contains(category) },
        set: { on in
          selection.remove(.all)
          if on { selection.insert(category) } else { selection.remove(category) }
        })
    ) {
      HStack {
        Text(category.title)
        Spacer()
        Text(verbatim: count == 0 ? "—" : "\(count)").foregroundStyle(.secondary).monospacedDigit()
      }
    }
    .disabled(count == 0 || selection.contains(.all))
  }

  private var allBinding: Binding<Bool> {
    Binding(
      get: { selection.contains(.all) },
      set: { on in selection = on ? [.all] : [] })
  }

  private func apply() {
    let files = context.files
    let chosen = selection
    context.apply {
      var written = 0
      for file in files {
        try Task.checkCancellation()
        try ImageMetadata.strip(file, removing: chosen)
        written += 1
      }
      return written == 1 ? String(localized: "Copy saved") : String(localized: "\(written) copies saved")
    }
  }
}
