// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import ConverterKit
import Foundation
import Testing

@testable import Convert

@Suite("Tier 1: ffmpeg jobs")
struct ConverterKitTests {
  private func exists(_ paths: Set<String>) -> (String) -> Bool { { paths.contains($0) } }

  @Test("a valid job passes the checks")
  func validJob() throws {
    let job = FFmpegJob(input: "/tmp/a/song.wav", output: "/tmp/a/song.mp3", preset: .mp3)
    try job.validate(fileExists: exists(["/tmp/a/song.wav"]))
  }

  @Test("relative paths, an existing output, another folder or a wrong extension are rejected")
  func rejectedJobs() {
    let input: Set = ["/tmp/a/x.wav"]
    #expect(throws: FFmpegJob.ValidationError.notAbsolute) {
      try FFmpegJob(input: "x.wav", output: "/tmp/a/x.mp3", preset: .mp3).validate(fileExists: exists(input))
    }
    #expect(throws: FFmpegJob.ValidationError.inputMissing) {
      try FFmpegJob(input: "/tmp/a/y.wav", output: "/tmp/a/y.mp3", preset: .mp3).validate(fileExists: exists(input))
    }
    #expect(throws: FFmpegJob.ValidationError.outputExists) {
      try FFmpegJob(input: "/tmp/a/x.wav", output: "/tmp/a/x.wav", preset: .mp3)
        .validate(fileExists: exists(input))
    }
    #expect(throws: FFmpegJob.ValidationError.differentFolder) {
      try FFmpegJob(input: "/tmp/a/x.wav", output: "/tmp/b/x.mp3", preset: .mp3).validate(fileExists: exists(input))
    }
    #expect(throws: FFmpegJob.ValidationError.wrongExtension) {
      try FFmpegJob(input: "/tmp/a/x.wav", output: "/tmp/a/x.ogg", preset: .mp3).validate(fileExists: exists(input))
    }
  }

  @Test("the command line never overwrites and puts the output last")
  func commandLine() {
    let job = FFmpegJob(input: "/tmp/a/x.mov", output: "/tmp/a/x.webm", preset: .webm)
    #expect(job.commandLine.contains("-n"))
    #expect(!job.commandLine.contains("-y"))
    #expect(job.commandLine.last == "/tmp/a/x.webm")
    #expect(job.commandLine.firstIndex(of: "-i").map { job.commandLine[$0 + 1] } == "/tmp/a/x.mov")
  }

  @Test("duration and progress are read from ffmpeg's output")
  func progressParsing() {
    #expect(FFmpegProgress.duration(in: "  Duration: 00:01:02.50, start: 0.000000") == 62.5)
    #expect(FFmpegProgress.duration(in: "nothing") == nil)
    #expect(FFmpegProgress.outTime(in: "out_time_us=31250000") == 31.25)
    #expect(FFmpegProgress.outTime(in: "frame=10") == nil)
  }

  @Test("tier 1 formats appear only if ffmpeg is present")
  func catalogTier1() {
    let audio = [URL(fileURLWithPath: "/tmp/a.wav")]
    #expect(!ConvertCatalog.formats(for: audio, ffmpeg: false).contains(.mp3))
    #expect(ConvertCatalog.formats(for: audio, ffmpeg: true).contains(.mp3))
    let image = [URL(fileURLWithPath: "/tmp/a.png")]
    #expect(ConvertCatalog.formats(for: image, ffmpeg: true).contains(.webp))
    let video = [URL(fileURLWithPath: "/tmp/a.mov")]
    #expect(ConvertCatalog.formats(for: video, ffmpeg: true).contains(.gifAnimation))
    #expect(OutputFormat.gifAnimation.fileExtension == "gif")
  }
}
