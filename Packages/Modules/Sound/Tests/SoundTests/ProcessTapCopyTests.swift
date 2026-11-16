// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import CoreAudio
import Foundation
import Testing

@testable import Sound

/// Copy of the tap to the output: the tap is always the last input, and the output
/// may have any channel layout.
@Suite("Sound: tap copy")
struct ProcessTapCopyTests {
  /// `Float32` buffer with `channels` interleaved channels.
  private final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float32>] = []

    init(_ layout: [(channels: Int, samples: [Float32])]) {
      list = AudioBufferList.allocate(maximumBuffers: layout.count)
      for (index, item) in layout.enumerated() {
        let pointer = UnsafeMutablePointer<Float32>.allocate(capacity: item.samples.count)
        pointer.initialize(from: item.samples, count: item.samples.count)
        storage.append(pointer)
        list[index] = AudioBuffer(
          mNumberChannels: UInt32(item.channels),
          mDataByteSize: UInt32(item.samples.count * MemoryLayout<Float32>.size),
          mData: pointer)
      }
    }

    func samples(_ index: Int) -> [Float32] {
      let count = Int(list[index].mDataByteSize) / MemoryLayout<Float32>.size
      return Array(UnsafeBufferPointer(start: storage[index], count: count))
    }

    deinit {
      for pointer in storage { pointer.deallocate() }
      free(list.unsafeMutablePointer)
    }
  }

  private let tap: [Float32] = [1, 2, 3, 4]  // two stereo frames: L=1,3 R=2,4

  private func run(input: Buffers, output: Buffers, scale: Float32 = 1) {
    ProcessTap.copyAndScale(
      input: UnsafePointer(input.list.unsafeMutablePointer),
      output: output.list.unsafeMutablePointer, scale: scale)
  }

  @Test("the device's microphone does not end up in the output: only the tap is read")
  func micBeforeTap() {
    let input = Buffers([(1, [9, 9]), (2, tap)])
    let output = Buffers([(2, [7, 7, 7, 7])])
    run(input: input, output: output)
    #expect(output.samples(0) == tap)
  }

  @Test("mono output: average of left and right")
  func mono() {
    let output = Buffers([(1, [7, 7])])
    run(input: Buffers([(2, tap)]), output: output)
    #expect(output.samples(0) == [1.5, 3.5])
  }

  @Test("non-interleaved output: one channel per buffer")
  func nonInterleaved() {
    let output = Buffers([(1, [7, 7]), (1, [7, 7])])
    run(input: Buffers([(2, tap)]), output: output)
    #expect(output.samples(0) == [1, 3])
    #expect(output.samples(1) == [2, 4])
  }

  @Test("8-channel output: L and R on the first two, the rest at zero")
  func eightChannels() {
    let output = Buffers([(8, [Float32](repeating: 7, count: 16))])
    run(input: Buffers([(2, tap)]), output: output)
    #expect(output.samples(0) == [1, 2, 0, 0, 0, 0, 0, 0, 3, 4, 0, 0, 0, 0, 0, 0])
  }

  @Test("volume at zero: silence")
  func muted() {
    let output = Buffers([(2, [7, 7, 7, 7])])
    run(input: Buffers([(2, tap)]), output: output, scale: 0)
    #expect(output.samples(0) == [0, 0, 0, 0])
  }

  @Test("the volume slider is perceptual")
  func perceptualGain() {
    #expect(ProcessTap.Scalar.gain(for: 1) == 1)
    #expect(ProcessTap.Scalar.gain(for: 0.5) == 0.125)
    #expect(ProcessTap.Scalar.gain(for: 2) == 1)
  }
}
