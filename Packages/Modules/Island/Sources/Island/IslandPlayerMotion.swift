// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Player animations. They are all event-driven (track change, click, opening):
/// once the spring is done nothing keeps running. With "Reduce Motion" only
/// fades remain.
enum IslandMotion {
  static let swap = Animation.spring(response: 0.5, dampingFraction: 0.74)
  static let press = Animation.spring(response: 0.28, dampingFraction: 0.55)
  static let pulse = Animation.spring(response: 0.45, dampingFraction: 0.6)

  /// For how long after ⏮ the track change enters from the left.
  static let previousWindow: TimeInterval = 3

  /// From which side the new track enters: from the left only right after ⏮.
  static func direction(lastPrevious: Date?, now: Date) -> CGFloat {
    guard let lastPrevious, now.timeIntervalSince(lastPrevious) < previousWindow else { return 1 }
    return -1
  }

  /// Artwork: the old one exits rotating to one side, the new one enters from the other.
  static func cover(direction: CGFloat, reduceMotion: Bool) -> AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .modifier(
        active: CoverSwap(offset: 46 * direction, angle: 62 * direction, scale: 0.6, opacity: 0, blur: 6),
        identity: CoverSwap()),
      removal: .modifier(
        active: CoverSwap(offset: -46 * direction, angle: -62 * direction, scale: 0.6, opacity: 0, blur: 6),
        identity: CoverSwap()))
  }

  /// A dropped file descends from the notch into the shelf coming into focus,
  /// like the artwork and the title when the track changes.
  static func shelfDrop(reduceMotion: Bool) -> AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .modifier(
        active: ShelfLanding(offset: -26, scale: 0.45, opacity: 0, blur: 6), identity: ShelfLanding()),
      removal: .modifier(active: ShelfLanding(offset: 0, scale: 0.6, opacity: 0, blur: 4), identity: ShelfLanding()))
  }

  /// Title and artist: they slide in the direction of the change, coming into focus.
  static func text(direction: CGFloat, reduceMotion: Bool) -> AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .modifier(active: TextSlide(offset: 28 * direction, opacity: 0, blur: 7), identity: TextSlide()),
      removal: .modifier(active: TextSlide(offset: -28 * direction, opacity: 0, blur: 7), identity: TextSlide()))
  }
}

private struct CoverSwap: ViewModifier {
  var offset: CGFloat = 0
  var angle: Double = 0
  var scale: CGFloat = 1
  var opacity: Double = 1
  var blur: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .blur(radius: blur)
      .scaleEffect(scale)
      .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
      .offset(x: offset)
      .opacity(opacity)
  }
}

private struct ShelfLanding: ViewModifier {
  var offset: CGFloat = 0
  var scale: CGFloat = 1
  var opacity: Double = 1
  var blur: CGFloat = 0

  func body(content: Content) -> some View {
    content.blur(radius: blur).scaleEffect(scale).offset(y: offset).opacity(opacity)
  }
}

private struct TextSlide: ViewModifier {
  var offset: CGFloat = 0
  var opacity: Double = 1
  var blur: CGFloat = 0

  func body(content: Content) -> some View {
    content.blur(radius: blur).offset(x: offset).opacity(opacity)
  }
}

/// The button squashes under the click and returns with a small bounce.
struct IslandPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.78 : 1)
      .opacity(configuration.isPressed ? 0.6 : 1)
      .animation(IslandMotion.press, value: configuration.isPressed)
  }
}

/// Symbol effect on click.
enum IslandControlEffect {
  case bounce, nudgeLeft, nudgeRight
}

/// Player control: symbol that reacts to the click and changes with a morph.
struct IslandControlButton: View {
  let symbol: String
  let size: CGFloat
  let label: LocalizedStringKey
  var effect: IslandControlEffect = .bounce
  let action: () -> Void
  @State private var taps = 0

  var body: some View {
    Button {
      taps += 1
      action()
    } label: {
      image
        .font(.system(size: size, weight: .regular))
        .contentTransition(.symbolEffect(.replace))
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(IslandPressStyle())
    .accessibilityLabel(Text(label))
    .help(Text(label))
  }

  @ViewBuilder private var image: some View {
    let base = Image(systemName: symbol)
    switch effect {
    case .bounce: base.symbolEffect(.bounce, value: taps)
    case .nudgeLeft: base.symbolEffect(.wiggle.left, value: taps)
    case .nudgeRight: base.symbolEffect(.wiggle.right, value: taps)
    }
  }
}

/// Ring that expands and fades when a track is added to favorites.
struct IslandHeartBurst: View {
  let trigger: Int

  private struct Ring {
    var scale: CGFloat = 0.3
    var opacity: Double = 0
  }

  var body: some View {
    Circle()
      .stroke(.pink, lineWidth: 2)
      .frame(width: 22, height: 22)
      .keyframeAnimator(initialValue: Ring(), trigger: trigger) { content, ring in
        content.scaleEffect(ring.scale).opacity(ring.opacity)
      } keyframes: { _ in
        KeyframeTrack(\.scale) {
          CubicKeyframe(0.3, duration: 0.01)
          CubicKeyframe(1.9, duration: 0.5)
        }
        KeyframeTrack(\.opacity) {
          CubicKeyframe(0.9, duration: 0.01)
          CubicKeyframe(0, duration: 0.5)
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// The player rows enter one after another when the island opens.
struct IslandStagger: ViewModifier {
  let index: Int
  let shown: Bool
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(y: shown || reduceMotion ? 0 : 10)
      .blur(radius: shown || reduceMotion ? 0 : 5)
      .animation(.spring(response: 0.42, dampingFraction: 0.8).delay(0.06 + Double(index) * 0.055), value: shown)
  }
}
