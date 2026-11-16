// SPDX-FileCopyrightText: 2026 Tsukumo contributors
// SPDX-License-Identifier: GPL-3.0-only

import Metal
import Testing

@testable import Duo

@Suite("Duo")
struct LidModelTests {
  @Test("lid open above the threshold: no fold")
  func openLidDoesNothing() {
    var model = LidModel(angle: 120)
    for _ in 0..<120 { model.step(target: 110, dt: 1.0 / 60) }
    #expect(model.tilt == 0)
  }

  @Test("lid almost closed: the fold gets close to the maximum")
  func closedLidFolds() {
    var model = LidModel(angle: 120)
    for _ in 0..<240 { model.step(target: 5, dt: 1.0 / 60) }
    #expect(model.progress > 0.9)
  }

  @Test("reopening the fold returns to zero")
  func reopeningClears() {
    var model = LidModel(angle: 120)
    for _ in 0..<240 { model.step(target: 5, dt: 1.0 / 60) }
    for _ in 0..<480 { model.step(target: 120, dt: 1.0 / 60) }
    #expect(model.tilt == 0)
  }

  @Test("in dynamic mode the fold relaxes on its own when the lid stops")
  func dynamicReleasesWhenStill() {
    var model = LidModel(angle: 110)
    model.dynamic = true
    for step in 0..<60 { model.step(target: 110 - Double(step), dt: 1.0 / 60) }
    #expect(model.tilt > 0)
    for _ in 0..<120 { model.step(target: 50, dt: 1.0 / 60) }
    #expect(model.tilt == 0)
  }

  @Test("a short, small jolt doesn't start the animation")
  func smallFlickIsIgnored() {
    var model = LidModel(angle: 110)
    model.dynamic = true
    var peak = 0.0
    // 6° down and up in about 0.2 s, at 60 Hz.
    for step in 0..<12 {
      let target = 110 - (step < 6 ? Double(step + 1) : Double(12 - step - 1))
      model.step(target: target, dt: 1.0 / 60)
      peak = max(peak, model.tilt)
    }
    for _ in 0..<60 { model.step(target: 110, dt: 1.0 / 60); peak = max(peak, model.tilt) }
    #expect(peak == 0)
  }

  @Test("the sensor report is little endian and limited to 0...360")
  func decodesAngle() {
    #expect(LidAngleSensor.degrees(high: 0, low: 94) == 94)
    #expect(LidAngleSensor.degrees(high: 1, low: 0x2C) == 300)
    #expect(LidAngleSensor.degrees(high: 2, low: 0) == nil)
  }
}

@Suite("Angle prediction")
struct AnglePredictorTests {
  @Test("when the reading is still the estimate stays on the angle")
  func stillStaysPut() {
    var predictor = AnglePredictor()
    var value = 0.0
    for step in 0..<20 { value = predictor.predict(raw: 90, at: Double(step) * 0.016) ?? 0 }
    #expect(abs(value - 90) < 0.01)
  }

  @Test("when closing the estimate leads the sample")
  func closingLeadsTheSample() {
    var predictor = AnglePredictor()
    _ = predictor.predict(raw: 100, at: 0)
    _ = predictor.predict(raw: 99, at: 0.1)
    let estimate = predictor.predict(raw: 98, at: 0.2) ?? 100
    #expect(estimate < 98)
  }
}

@Suite("Shader")
struct ShaderTests {
  @Test("the Metal source compiles and has the two functions")
  func compiles() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let library = try device.makeLibrary(source: Shaders.source, options: nil)
    #expect(library.makeFunction(name: "foldVertex") != nil)
    #expect(library.makeFunction(name: "foldFragment") != nil)
  }
}
