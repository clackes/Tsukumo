// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import DesignSystem
import QuickLookThumbnailing
import SwiftUI

/// Files row at the bottom of the open island, with the AirDrop zone on the right.
struct IslandShelfView: View {
  let model: IslandModel
  let actions: IslandActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Grows with each file that arrives: makes the box bounce once.
  @State private var landed = 0

  /// The dragged file would be dropped into the shelf (not on AirDrop).
  private var isDropTarget: Bool { model.isDragging && !model.dragOverAirDrop }

  var body: some View {
    HStack(spacing: TsukumoTokens.Spacing.sm) {
      dropBox
      airDrop
    }
    .padding(.horizontal, TsukumoTokens.Spacing.md)
    .padding(.bottom, TsukumoTokens.Spacing.sm)
    .frame(height: IslandGeometry.shelfHeight)
    .onChange(of: model.shelf.count) { old, new in
      if new > old { landed += 1 }
    }
  }

  /// Files zone: during a drag it becomes a dashed box that
  /// lights up when the file is over it, like the AirDrop zone next to it.
  private var dropBox: some View {
    ZStack {
      if model.shelf.isEmpty {
        VStack(spacing: 3) {
          if model.isDragging {
            Image(systemName: "tray.and.arrow.down.fill")
              .font(.system(size: 17))
              .symbolEffect(.bounce, value: isDropTarget)
              .transition(.scale(scale: 0.6).combined(with: .opacity))
          }
          Text("Drop files here")
            .font(.system(size: model.isDragging ? 10 : 12, weight: model.isDragging ? .medium : .regular))
        }
        .foregroundStyle(isDropTarget ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: TsukumoTokens.Spacing.sm) {
            ForEach(model.shelf) { item in
              ShelfItemView(item: item, actions: actions)
                .transition(IslandMotion.shelfDrop(reduceMotion: reduceMotion))
            }
          }
          .padding(.horizontal, model.isDragging ? TsukumoTokens.Spacing.sm : 0)
          .animation(IslandMotion.swap, value: model.shelf.map(\.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }
    }
    .frame(height: 58)
    .background {
      if model.isDragging {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.white.opacity(isDropTarget ? 0.14 : 0.05))
          .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(
                .white.opacity(isDropTarget ? 0.7 : 0.25),
                style: StrokeStyle(lineWidth: 1.5, dash: isDropTarget ? [] : [5, 4]))
          }
          .transition(.opacity)
      }
    }
    .scaleEffect(isDropTarget && !reduceMotion ? 1.02 : 1)
    .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : landed) { content, scale in
      content.scaleEffect(scale)
    } keyframes: { _ in
      CubicKeyframe(1.045, duration: 0.12)
      SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
    }
    .animation(IslandMotion.press, value: isDropTarget)
    .animation(IslandMotion.swap, value: model.isDragging)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Shelf"))
  }

  private var airDrop: some View {
    Button {
      actions.airDropAll()
    } label: {
      VStack(spacing: 3) {
        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 17))
        Text(verbatim: "AirDrop").font(.system(size: 10, weight: .medium))
      }
      .foregroundStyle(model.dragOverAirDrop ? .white : .blue)
      .frame(width: IslandGeometry.airDropWidth - TsukumoTokens.Spacing.md, height: 58)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(model.dragOverAirDrop ? AnyShapeStyle(.blue) : AnyShapeStyle(.white.opacity(0.1)))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.shelf.isEmpty)
    .accessibilityLabel(Text("Send with AirDrop"))
    .help(Text("Send with AirDrop"))
  }
}

private struct ShelfItemView: View {
  let item: ShelfItem
  let actions: IslandActions
  @State private var thumbnail: NSImage?
  @State private var isHovering = false

  var body: some View {
    VStack(spacing: 2) {
      Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: item.url.path))
        .resizable()
        .scaledToFit()
        .frame(width: 40, height: 40)
      Text(verbatim: item.url.lastPathComponent)
        .font(.system(size: 10))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: 60)
    }
    .foregroundStyle(.white)
    .overlay(alignment: .topTrailing) {
      if isHovering {
        Button {
          actions.removeFromShelf(item.id)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(.white, .gray)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove"))
        .help(Text("Remove"))
      }
    }
    .onHover { isHovering = $0 }
    .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
    .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
    .contextMenu {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
      Button("Remove") { actions.removeFromShelf(item.id) }
    }
    .task(id: item.url) { thumbnail = await Self.thumbnail(for: item.url) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(verbatim: item.url.lastPathComponent))
  }

  /// Side of the thumbnail in points: the same as the image's frame.
  private static let thumbnailSide: CGFloat = 40

  /// Thumbnail of the content; if QuickLook does not produce it the file's icon remains.
  private static func thumbnail(for url: URL) async -> NSImage? {
    let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: thumbnailSide, height: thumbnailSide),
      scale: scale,
      representationTypes: .thumbnail
    )
    guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage else {
      return nil
    }
    // The image is in pixels: the `NSImage` size is given in points.
    return NSImage(
      cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    )
  }
}
