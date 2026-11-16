// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import ConverterKit
import Foundation
import Testing

@testable import Convert

@Suite("Convert robustness")
struct RobustnessTests {
  @Test("the mkv preset copies only video, audio and subtitles, without data streams")
  func mkvPreset() {
    let args = FFmpegPreset.mkv.arguments
    #expect(args.contains("-dn"))
    #expect(!args.contains("0"))
    #expect(args.contains("0:v?") && args.contains("0:a?") && args.contains("0:s?"))
    #expect(args.suffix(2) == ["-c", "copy"])
  }

  @Test("the command line doesn't open the network and can write to a temporary file")
  func commandLineSafety() {
    let job = FFmpegJob(input: "/tmp/a/x.mov", output: "/tmp/a/x.webm", preset: .webm)
    let line = job.commandLine(writingTo: "/tmp/a/.tsukumo-1.webm")
    guard let option = line.firstIndex(of: "-protocol_whitelist"), let input = line.firstIndex(of: "-i") else {
      Issue.record("expected options are missing")
      return
    }
    #expect(option < input)
    #expect(line[option + 1] == "file,pipe")
    #expect(line.last == "/tmp/a/.tsukumo-1.webm")
    #expect(!line.contains("/tmp/a/x.webm"))
  }

  @Test("the temporary name is hidden, next to the output and with the preset's extension")
  func temporaryName() {
    let job = FFmpegJob(input: "/tmp/a/x.wav", output: "/tmp/a/x.mp3", preset: .mp3)
    #expect(job.temporaryOutput(token: "ABC") == "/tmp/a/.tsukumo-ABC.mp3")
  }

  @Test("a name with % on an image is rejected, on a video it isn't")
  func percentInImageName() {
    let exists: (String) -> Bool = { $0 == "/tmp/a/img%03d.png" || $0 == "/tmp/a/film%1.mov" }
    #expect(throws: FFmpegJob.ValidationError.unsupportedName) {
      try FFmpegJob(input: "/tmp/a/img%03d.png", output: "/tmp/a/img%03d.webp", preset: .webp)
        .validate(fileExists: { $0 == "/tmp/a/img%03d.png" })
    }
    #expect(throws: Never.self) {
      try FFmpegJob(input: "/tmp/a/film%1.mov", output: "/tmp/a/film%1.mkv", preset: .mkv).validate(fileExists: exists)
    }
  }

  @Test("validation errors have readable text")
  func validationMessages() {
    let all: [FFmpegJob.ValidationError] = [
      .notAbsolute, .inputMissing, .outputExists, .differentFolder, .wrongExtension, .unsupportedName,
    ]
    for error in all { #expect(!error.message.isEmpty && !error.message.contains("ValidationError")) }
  }

  @Test("the duration is read only if the line is complete")
  func durationNeedsCompleteValue() {
    #expect(FFmpegProgress.duration(in: "  Duration: 00:01:0") == nil)
    #expect(FFmpegProgress.duration(in: "  Duration: 00:01:02.5") == nil)
    #expect(FFmpegProgress.duration(in: "  Duration: 00:01:02.50,") == 62.5)
    #expect(FFmpegProgress.duration(in: "  Duration: 01:00:00.00\n") == 3600)
    #expect(FFmpegProgress.duration(in: "  Duration: N/A, start: 0") == nil)
  }

  @Test("the line buffer holds back the last incomplete piece")
  func lineBuffer() {
    var buffer = LineBuffer()
    #expect(buffer.append("frame=1\nout_time_") == ["frame=1"])
    #expect(buffer.append("us=2000000\nprog") == ["out_time_us=2000000"])
    #expect(buffer.append("ress=end\n") == ["progress=end"])
    #expect(buffer.append("") == [])
  }

  @Test("PDF page numbers have leading zeros")
  func pdfPageSuffix() {
    #expect(ImageConverter.pageSuffix(index: 0, count: 1) == "")
    #expect(ImageConverter.pageSuffix(index: 0, count: 9) == "-1")
    #expect(ImageConverter.pageSuffix(index: 1, count: 12) == "-02")
    #expect(ImageConverter.pageSuffix(index: 99, count: 100) == "-100")
    #expect(ImageConverter.pageSuffix(index: 0, count: 100) == "-001")
  }

  @Test("progress never goes backwards")
  func monotonic() {
    let progress = MonotonicProgress()
    #expect(progress.advance(to: 0.2) == 0.2)
    #expect(progress.advance(to: 0.1) == nil)
    #expect(progress.advance(to: 0.2) == nil)
    #expect(progress.advance(to: 0.5) == 0.5)
  }

  @MainActor
  @Test("a group's outcome distinguishes succeeded, failed and mixed")
  func batchSummary() {
    #expect(ConvertModule.summary(created: ["a.png"], failures: []) == .done("a.png"))
    #expect(ConvertModule.summary(created: [], failures: ["Error one", "Error two"]) == .failed("Error one"))
    let mixed = ConvertModule.summary(created: ["a.png", "b.png"], failures: ["x"])
    guard case .failed(let text) = mixed else {
      Issue.record("expected a mixed outcome")
      return
    }
    #expect(text.contains("2") && text.contains("1"))
  }

  @MainActor
  @Test("conversion errors become readable text")
  func errorMessages() {
    let file = URL(fileURLWithPath: "/tmp/a/x.heic")
    #expect(ConvertModule.message(for: ConversionError.unreadable("x.heic"), file: file).contains("x.heic"))
    #expect(ConvertModule.message(for: FFmpegError.failed("Cancelled"), file: file) == "Cancelled")
  }
}
