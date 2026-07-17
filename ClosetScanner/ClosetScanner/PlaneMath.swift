//
//  PlaneMath.swift
//  ClosetScanner
//
//  Pure geometry: robust plane fitting on LiDAR point windows, plane-to-plane
//  gaps (the actual measurements), 3-plane corner intersection, and inch
//  formatting. No ARKit imports — everything here runs in unit tests.
//

import Foundation
import simd

// MARK: - Surfaces the user can capture

enum SurfaceLabel: String, CaseIterable, Identifiable {
    case leftWall, rightWall, backWall, frontWall, floor, ceiling
    case soffitBottom, soffitFace
    case doorLeftJamb, doorRightJamb, doorHead

    var id: String { rawValue }

    /// User-captured interior surfaces, in capture order. The back wall comes
    /// before the front wall so the front capture can be checked against it.
    static let coreOrder: [SurfaceLabel] = [.leftWall, .rightWall, .backWall, .frontWall, .floor, .ceiling]

    var title: String {
        switch self {
        case .leftWall: "Left wall"
        case .rightWall: "Right wall"
        case .backWall: "Back wall"
        case .frontWall: "Front wall"
        case .floor: "Floor"
        case .ceiling: "Ceiling"
        case .soffitBottom: "Soffit underside"
        case .soffitFace: "Soffit face"
        case .doorLeftJamb: "Door jamb L"
        case .doorRightJamb: "Door jamb R"
        case .doorHead: "Above door"
        }
    }

    var short: String {
        switch self {
        case .leftWall: "Left"
        case .rightWall: "Right"
        case .backWall: "Back"
        case .frontWall: "Front"
        case .floor: "Floor"
        case .ceiling: "Ceiling"
        case .soffitBottom: "Soffit ⌵"
        case .soffitFace: "Soffit face"
        case .doorLeftJamb: "Jamb L"
        case .doorRightJamb: "Jamb R"
        case .doorHead: "Above door"
        }
    }

    var hint: String {
        switch self {
        case .frontWall: "Aim across at the inside face of the front wall, beside the opening"
        case .soffitBottom: "Aim up at the underside of the soffit"
        case .soffitFace: "Aim at the soffit's vertical face (the side facing the back wall)"
        case .doorLeftJamb: "From outside, aim at the inner LEFT wall of the door opening (the reveal)"
        case .doorRightJamb: "From outside, aim at the inner RIGHT wall of the door opening (the reveal)"
        case .doorHead: "From INSIDE the closet, frame the top edge of the opening — half wall above, half opening"
        default: "Aim the frame at a bare patch of the \(title.lowercased()), then Capture"
        }
    }

    /// Fraction of the depth map used as the sampling window. Big flat
    /// surfaces get a wide window; narrow jamb reveals a tight one; the
    /// above-door edge capture needs room for wall AND opening.
    var windowFraction: Double {
        switch self {
        case .leftWall, .rightWall, .backWall, .floor, .ceiling: 0.42
        case .frontWall, .soffitBottom, .soffitFace: 0.20
        case .doorLeftJamb, .doorRightJamb: 0.14
        case .doorHead: 0.30
        }
    }

    var expectsVertical: Bool {
        switch self {
        case .floor, .ceiling, .soffitBottom, .doorHead: false
        default: true
        }
    }

    var phase: String {
        switch self {
        case .soffitBottom, .soffitFace: "Soffit"
        case .doorLeftJamb, .doorRightJamb: "Door · from outside"
        case .doorHead: "Door · from inside"
        default: "Closet interior"
        }
    }

    /// Capture sequence: soffit (if any) → interior → door last. The door
    /// captures need the earlier planes: jamb orientation is checked against
    /// the back wall, and the head capture clips its rays to the opening.
    static func captureOrder(hasSoffit: Bool) -> [SurfaceLabel] {
        (hasSoffit ? [.soffitBottom, .soffitFace] : [])
            + coreOrder
            + [.doorLeftJamb, .doorRightJamb, .doorHead]
    }
}

// MARK: - Plane fit

struct PlaneFit {
    /// Unit normal, oriented toward the camera position at capture time.
    let normal: SIMD3<Double>
    let centroid: SIMD3<Double>
    /// 1σ of point-to-plane residuals (m) — surface flatness + sensor noise.
    let sigma: Double
    let inlierFraction: Double
    let count: Int
    /// Subsampled inlier points, used for gap statistics.
    let samples: [SIMD3<Double>]
}

/// Least-squares plane through points: centroid + smallest eigenvector of the
/// covariance. Returns nil if degenerate.
func lsqPlane(_ pts: [SIMD3<Double>]) -> (normal: SIMD3<Double>, centroid: SIMD3<Double>, variance: Double)? {
    guard pts.count >= 50 else { return nil }
    let n = Double(pts.count)
    var c = SIMD3<Double>()
    for p in pts { c += p }
    c /= n
    var m = simd_double3x3()
    for p in pts {
        let d = p - c
        m.columns.0 += d * d.x
        m.columns.1 += d * d.y
        m.columns.2 += d * d.z
    }
    let (vals, vecs) = eigenSymmetric3(m)
    var minI = 0
    if vals[1] < vals[minI] { minI = 1 }
    if vals[2] < vals[minI] { minI = 2 }
    let normal = simd_normalize(vecs[minI])
    guard normal.x.isFinite else { return nil }
    return (normal, c, max(vals[minI], 0) / n)
}

/// Eigen-decomposition of a symmetric 3×3 via cyclic Jacobi rotations.
/// Returns unsorted eigenvalues and matching eigenvector columns.
func eigenSymmetric3(_ m0: simd_double3x3) -> (values: [Double], vectors: simd_double3x3) {
    var a = m0
    var v = matrix_identity_double3x3
    for _ in 0..<30 {
        // simd subscripting is [column][row]; symmetric, so a[q][p] = a_pq
        var p = 0, q = 1
        var apq = a[1][0]
        if abs(a[2][0]) > abs(apq) { p = 0; q = 2; apq = a[2][0] }
        if abs(a[2][1]) > abs(apq) { p = 1; q = 2; apq = a[2][1] }
        if abs(apq) < 1e-15 { break }
        let theta = (a[q][q] - a[p][p]) / (2 * apq)
        let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
        let c = 1 / (t * t + 1).squareRoot()
        let s = t * c
        var g = matrix_identity_double3x3
        g[p][p] = c; g[q][q] = c
        g[q][p] = s; g[p][q] = -s
        a = g.transpose * a * g
        v = v * g
    }
    return ([a[0][0], a[1][1], a[2][2]], v)
}

/// Robust fit: trimmed least squares (drop worst 25%), then re-admit
/// everything within a MAD-based band. Handles hangers/boxes clipping the
/// sampling window without dragging the plane.
func fitPlane(points: [SIMD3<Float>], viewPoint: SIMD3<Double>) -> PlaneFit? {
    guard points.count >= 200 else { return nil }
    let all = points.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }

    guard let first = lsqPlane(all) else { return nil }
    var res = all.map { abs(simd_dot($0 - first.centroid, first.normal)) }
    let keepCount = max(all.count * 3 / 4, 50)
    let cutoff = res.sorted()[keepCount - 1]
    var kept = zip(all, res).filter { $0.1 <= cutoff }.map(\.0)
    guard let trimmed = lsqPlane(kept) else { return nil }

    // Re-admit: band from the median residual of ALL points vs the trimmed fit.
    res = all.map { abs(simd_dot($0 - trimmed.centroid, trimmed.normal)) }
    let mad = res.sorted()[res.count / 2]
    let band = max(3 * 1.4826 * mad, 0.004)
    kept = zip(all, res).filter { $0.1 <= band }.map(\.0)
    guard kept.count >= 200, let fit = lsqPlane(kept) else { return nil }

    var normal = fit.normal
    if simd_dot(viewPoint - fit.centroid, normal) < 0 { normal = -normal }

    let strideBy = max(kept.count / 1200, 1)
    var samples: [SIMD3<Double>] = []
    samples.reserveCapacity(kept.count / strideBy + 1)
    var i = 0
    while i < kept.count { samples.append(kept[i]); i += strideBy }

    return PlaneFit(normal: normal,
                    centroid: fit.centroid,
                    sigma: fit.variance.squareRoot(),
                    inlierFraction: Double(kept.count) / Double(all.count),
                    count: kept.count,
                    samples: samples)
}

// MARK: - Measurements

struct GapResult {
    let meters: Double
    let standardError: Double
    let angleDegrees: Double
}

/// Distance between two (near-)parallel surfaces: mean point-of-A-to-plane-B
/// distance, symmetrized. Robust to obstructed edges — planes extend forever.
func planeGap(_ a: PlaneFit, _ b: PlaneFit) -> GapResult {
    let angle = acos(min(1, abs(simd_dot(a.normal, b.normal)))) * 180 / .pi
    func stats(_ pts: [SIMD3<Double>], to ref: PlaneFit) -> (mean: Double, se: Double) {
        let ds = pts.map { abs(simd_dot($0 - ref.centroid, ref.normal)) }
        let m = ds.reduce(0, +) / Double(ds.count)
        let variance = ds.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(ds.count - 1, 1))
        return (m, (variance / Double(ds.count)).squareRoot())
    }
    let sa = stats(a.samples, to: b)
    let sb = stats(b.samples, to: a)
    return GapResult(meters: (sa.mean + sb.mean) / 2,
                     standardError: (sa.se * sa.se + sb.se * sb.se).squareRoot() / 2,
                     angleDegrees: angle)
}

// MARK: - Edge captures (door)

/// Where the ray from `origin` through `p` crosses a plane. Nil if parallel
/// or the crossing is behind the origin.
func rayPlaneCrossing(origin: SIMD3<Double>, through p: SIMD3<Double>,
                      planeNormal n: SIMD3<Double>, planePoint c: SIMD3<Double>) -> SIMD3<Double>? {
    let dir = p - origin
    let denom = simd_dot(dir, n)
    guard abs(denom) > 1e-9 else { return nil }
    let t = simd_dot(c - origin, n) / denom
    guard t > 0 else { return nil }
    return origin + dir * t
}

/// Rays that pass through the door opening cross the wall plane below the
/// head; their crossings fill the opening up to a sharp cutoff at the head
/// line. Returns a horizontal plane at that height (99th percentile, robust
/// to stray flying pixels) whose samples are the edge points.
func headLineFit(crossings: [SIMD3<Double>]) -> PlaneFit? {
    guard crossings.count >= 150 else { return nil }
    let ys = crossings.map(\.y).sorted()
    let y = ys[Int(Double(ys.count) * 0.99)]
    let edge = crossings.filter { $0.y > y - 0.008 && $0.y <= y + 0.002 }
    guard edge.count >= 20 else { return nil }
    var centroid = edge.reduce(SIMD3<Double>(), +) / Double(edge.count)
    centroid.y = y
    // Samples flattened to the head height so plane-gap stats stay exact.
    let flat = edge.map { SIMD3($0.x, y, $0.z) }
    return PlaneFit(normal: SIMD3(0, 1, 0), centroid: centroid, sigma: 0.004,
                    inlierFraction: 1, count: edge.count, samples: flat)
}

/// Corner point where three planes meet.
func planeIntersection(_ p1: PlaneFit, _ p2: PlaneFit, _ p3: PlaneFit) -> SIMD3<Double>? {
    let m = simd_double3x3(rows: [p1.normal, p2.normal, p3.normal])
    guard abs(m.determinant) > 1e-6 else { return nil }
    let d = SIMD3<Double>(simd_dot(p1.normal, p1.centroid),
                          simd_dot(p2.normal, p2.centroid),
                          simd_dot(p3.normal, p3.centroid))
    return m.inverse * d
}

struct MeasurementDef {
    let name: String
    let a: SurfaceLabel
    let b: SurfaceLabel
}

let measurementDefs: [MeasurementDef] = [
    MeasurementDef(name: "Width", a: .leftWall, b: .rightWall),
    MeasurementDef(name: "Depth", a: .backWall, b: .frontWall),
    MeasurementDef(name: "Height", a: .floor, b: .ceiling),
    MeasurementDef(name: "Height under soffit", a: .floor, b: .soffitBottom),
    MeasurementDef(name: "Soffit depth", a: .frontWall, b: .soffitFace),
    MeasurementDef(name: "Door width", a: .doorLeftJamb, b: .doorRightJamb),
    MeasurementDef(name: "Door height", a: .floor, b: .doorHead),
]

// MARK: - Inch formatting

/// Reduced sixteenth fraction, e.g. 8 → "1/2".
func sixteenthsString(_ sixteenths: Int) -> String {
    var num = sixteenths, den = 16
    while num % 2 == 0, num > 0 { num /= 2; den /= 2 }
    return "\(num)/\(den)"
}

/// Meters → inches rounded to the nearest 1/16″, e.g. "27 3/16″".
func inchString(_ meters: Double) -> String {
    let total = Int((meters / 0.0254 * 16).rounded())
    let whole = total / 16
    let frac = total % 16
    if frac == 0 { return "\(whole)″" }
    let f = sixteenthsString(frac)
    return whole > 0 ? "\(whole) \(f)″" : "\(f)″"
}

func cmString(_ meters: Double) -> String {
    String(format: "%.1f cm", meters * 100)
}

/// Meters → feet + inches to the nearest 1/16″, e.g. "8′ 4 1/16″".
func feetInchString(_ meters: Double) -> String {
    let total = Int((meters / 0.0254 * 16).rounded())
    let feet = total / (16 * 12)
    let rem = total % (16 * 12)
    if rem == 0 { return feet > 0 ? "\(feet)′" : "0″" }
    let whole = rem / 16
    let frac = rem % 16
    let inches: String = if frac == 0 { "\(whole)″" }
        else if whole > 0 { "\(whole) \(sixteenthsString(frac))″" }
        else { "\(sixteenthsString(frac))″" }
    return feet > 0 ? "\(feet)′ \(inches)" : inches
}
