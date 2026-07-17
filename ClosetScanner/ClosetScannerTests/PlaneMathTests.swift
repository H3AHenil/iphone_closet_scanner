//
//  PlaneMathTests.swift
//  ClosetScannerTests
//
//  The one runnable check the measurement math must pass: synthetic walls at
//  known distances, with noise and clutter, must come back correct.
//

import Testing
import simd
@testable import ClosetScanner

/// Deterministic RNG so failures reproduce.
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Points on the plane x = x0, jittered along x by ±noise.
private func wall(x: Double, n: Int, noise: Double, rng: inout LCG) -> [SIMD3<Float>] {
    (0..<n).map { _ in
        let y = Double.random(in: 0...2.0, using: &rng)
        let z = Double.random(in: -0.5...0.5, using: &rng)
        let e = Double.random(in: -noise...noise, using: &rng)
        return SIMD3<Float>(Float(x + e), Float(y), Float(z))
    }
}

private func syntheticPlane(normal: SIMD3<Double>, throughPoint p: SIMD3<Double>) -> PlaneFit {
    PlaneFit(normal: simd_normalize(normal), centroid: p, sigma: 0.001,
             inlierFraction: 1, count: 1000, samples: [p])
}

struct PlaneMathTests {

    @Test func captureOrderReflectsSoffitChoice() {
        #expect(SurfaceLabel.captureOrder(hasSoffit: true) == [
            .soffitBottom, .soffitFace,
            .leftWall, .rightWall, .backWall, .frontWall, .floor, .ceiling,
            .doorLeftJamb, .doorRightJamb, .doorHead,
        ])
        #expect(SurfaceLabel.captureOrder(hasSoffit: false) == [
            .leftWall, .rightWall, .backWall, .frontWall, .floor, .ceiling,
            .doorLeftJamb, .doorRightJamb, .doorHead,
        ])
    }

    @Test func eigenRecoversDiagonal() {
        let m = simd_double3x3(diagonal: SIMD3(3, 1, 2))
        let (values, vectors) = eigenSymmetric3(m)
        #expect(abs(values.sorted()[0] - 1) < 1e-12)
        #expect(abs(values.sorted()[2] - 3) < 1e-12)
        let minI = values.firstIndex(of: values.min()!)!
        #expect(abs(abs(vectors[minI].y) - 1) < 1e-9) // λ=1 belongs to the y axis
    }

    @Test func fitRecoversNoisyWall() {
        var rng = LCG(state: 7)
        let fit = fitPlane(points: wall(x: 0, n: 8000, noise: 0.004, rng: &rng),
                           viewPoint: SIMD3(1, 1, 0))
        #expect(fit != nil)
        #expect(fit!.normal.x > 0.9999)                 // oriented toward viewpoint
        #expect(abs(fit!.centroid.x) < 0.0005)
        #expect(fit!.sigma < 0.004)
    }

    @Test func fitRejectsClutterCluster() {
        // 25% of the window is a box face 25 cm in front of the wall.
        var rng = LCG(state: 21)
        var pts = wall(x: 0, n: 6000, noise: 0.004, rng: &rng)
        pts += wall(x: 0.25, n: 2000, noise: 0.004, rng: &rng)
        let fit = fitPlane(points: pts, viewPoint: SIMD3(1, 1, 0))
        #expect(fit != nil)
        #expect(abs(fit!.centroid.x) < 0.002)           // box didn't drag the plane
        #expect(fit!.inlierFraction < 0.85)             // and was actually excluded
    }

    @Test func gapMatchesKnownWidth() {
        var rng = LCG(state: 42)
        let a = fitPlane(points: wall(x: 0, n: 8000, noise: 0.004, rng: &rng),
                         viewPoint: SIMD3(0.3, 1, 0))!
        let b = fitPlane(points: wall(x: 0.686, n: 8000, noise: 0.004, rng: &rng),
                         viewPoint: SIMD3(0.3, 1, 0))!
        let gap = planeGap(a, b)
        #expect(abs(gap.meters - 0.686) < 0.001)        // sub-mm on synthetic data
        #expect(gap.angleDegrees < 0.5)
    }

    @Test func cornerIntersection() {
        let corner = planeIntersection(
            syntheticPlane(normal: SIMD3(1, 0, 0), throughPoint: SIMD3(1, 5, 5)),
            syntheticPlane(normal: SIMD3(0, 1, 0), throughPoint: SIMD3(5, 2, 5)),
            syntheticPlane(normal: SIMD3(0, 0, 1), throughPoint: SIMD3(5, 5, 3)))
        #expect(corner != nil)
        #expect(simd_length(corner! - SIMD3(1, 2, 3)) < 1e-9)
    }

    @Test func parallelPlanesDontIntersect() {
        let a = syntheticPlane(normal: SIMD3(1, 0, 0), throughPoint: .zero)
        let b = syntheticPlane(normal: SIMD3(1, 0, 0), throughPoint: SIMD3(1, 0, 0))
        let c = syntheticPlane(normal: SIMD3(0, 1, 0), throughPoint: .zero)
        #expect(planeIntersection(a, b, c) == nil)
    }

    @Test func rayCrossingHitsPlane() {
        let x = rayPlaneCrossing(origin: SIMD3(0, 0, 2), through: SIMD3(0, 1, -1),
                                 planeNormal: SIMD3(0, 0, 1), planePoint: .zero)
        #expect(x != nil)
        #expect(simd_length(x! - SIMD3(0, 2.0 / 3, 0)) < 1e-9)
        // Crossing behind the origin is rejected.
        #expect(rayPlaneCrossing(origin: SIMD3(0, 0, 2), through: SIMD3(0, 0, 3),
                                 planeNormal: SIMD3(0, 0, 1), planePoint: .zero) == nil)
    }

    @Test func headLineFindsTopOfOpening() {
        // Through-the-opening crossings fill the wall plane up to the head at y = 2.03.
        var rng = LCG(state: 5)
        let crossings = (0..<3000).map { _ in
            SIMD3(Double.random(in: -0.4...0.4, using: &rng),
                  Double.random(in: 1.5...2.03, using: &rng), 0.0)
        }
        let fit = headLineFit(crossings: crossings)
        #expect(fit != nil)
        #expect(abs(fit!.centroid.y - 2.03) < 0.008)
        #expect(fit!.normal.y == 1)
        #expect(fit!.samples.allSatisfy { $0.y == fit!.centroid.y })
    }

    @Test func feetInchFormatting() {
        #expect(feetInchString(100.0625 * 0.0254) == "8′ 4 1/16″")
        #expect(feetInchString(27.875 * 0.0254) == "2′ 3 7/8″")
        #expect(feetInchString(11.5 * 0.0254) == "11 1/2″")
        #expect(feetInchString(24 * 0.0254) == "2′")
    }

    @Test func inchFormatting() {
        #expect(inchString(27.1875 * 0.0254) == "27 3/16″")
        #expect(inchString(27.5 * 0.0254) == "27 1/2″")
        #expect(inchString(15.97 * 0.0254) == "16″")     // rounds up across the whole
        #expect(inchString(0.1875 * 0.0254) == "3/16″")
    }

}
