# ClosetScanner

iPhone (17 Pro Max, LiDAR) app that scans a reach-in closet, digitally empties it on screen, and reports its dimensions to the nearest 1/16″ with a stated uncertainty.

## How to use it

1. Open the app — camera starts immediately. Toggle the **torch** if the closet is dark (tracking needs light; LiDAR doesn't).
2. Aim the dashed reticle at a **bare patch** of each surface (chips along the bottom: Left → Right → Back → Front → Floor → Ceiling, auto-advancing) and tap **Capture**. Hold still ~1 second per surface. Boxes and cabinets are fine — just aim at any visible patch of the wall itself; edges and corners are never needed.
3. After the six core surfaces: the closet **renders empty** — an opaque clean shell drawn at the fitted planes covers everything inside — with W × D × H painted on the back wall and a live measurement card on screen.
4. Optional chips: **soffit underside + soffit face** (adds under-soffit height and soffit depth, and draws the soffit block in the shell), and **door jambs + head** captured from outside (door width/height) — only aimed surfaces are ever captured, so the rest of the room stays out of the scan.
5. Tap any measurement row to **calibrate**: enter the tape-measured true value (e.g. `27 3/16`) and a scale correction is applied to everything and persisted.

## Architecture

```
ARKit (world tracking + LiDAR smoothedSceneDepth, plane detection for cross-check)
   │  40 frames × central depth window, confidence == .high only
   ▼
Unprojection (scaled intrinsics → world points, ~50–150k pts per capture)
   ▼
Robust plane fit (PlaneMath.swift — pure Swift, unit-tested)
   │  trimmed least squares (drop worst 25%) → MAD re-admission → final fit
   │  covariance smallest-eigenvector via 3×3 Jacobi; σ, inlier %, warnings
   ▼
Measurements = plane-to-plane gaps (symmetrized mean point→plane distance)
   │  × persisted calibration factor; ± = SE ⊕ scale error; parallelism angle
   ▼
RealityKit overlay: opaque clean shell + soffit block + dimension text
SwiftUI HUD: reticle, chips, capture ring, measurement card, calibration
```

Three files: `PlaneMath.swift` (geometry, no ARKit — fully testable), `CaptureController.swift` (session + overlay), `ScanView.swift` (UI).

## Why this method (alternatives considered)

| Method | Verdict |
|---|---|
| **Apple RoomPlan** (tried first, on `main`) | Built for whole rooms ≥ ~2×2 m; unreliable in a 24″-deep reach-in, walls get eaten by clutter, ~±2 cm at best, and it happily models the rest of the room when you scan the door — the opposite of the brief. |
| **Tap-to-measure raycasts** | Two single raycasts = two noisy samples (~±5–10 mm each) and you must hit the true edge, which is exactly what cabinets/boxes hide. |
| **Depth-window plane fitting** (chosen) | Averages tens of thousands of LiDAR samples per surface → mm-level plane locations; a plane extends infinitely, so obstructed edges/corners don't matter; dimensions are plane-to-plane gaps; soffits and jambs are just more planes; nothing outside the reticle is ever captured. |
| Cross-check kept in-app | Every capture also raycasts ARKit's independent plane-anchor estimate; each measurement row shows the Δ between the two detectors (✓ when within 1/8″). |

## Accuracy: budget, calibration, validation

**Error budget per dimension** (~60–100 cm spans):

| Source | Magnitude | Mitigation |
|---|---|---|
| LiDAR per-pixel depth noise | ±5–15 mm | Averaged over ~10⁵ high-confidence samples → SE ≪ 1 mm |
| Surface texture / non-flatness | σ shown per capture | Robust trim + MAD rejection; warning if σ > 8 mm or < 60% flat |
| ARKit world-scale (VIO) error | ~0.3–0.5% of span (≈ 2–3 mm) | **Dominant term** → one-tap tape calibration knocks it to ~0.15% |
| Out-of-parallel walls | real geometry | Angle shown; > 1.5° flagged on the row |
| Tape-measure ground truth itself | ±1/32″ | Measure at the same spots the app sampled |

Displayed ± is the standard error combined with the scale term, floored at 1/32″. Uncalibrated, expect ±1/8″; **after calibration, ±1/16″ is the honest claim** in good conditions — and the app says so on every row rather than pretending to more.

**Validation protocol (demoable live):**
1. Tape-measure the closet width/depth/height (ground truth, ±1/32″).
2. Scan; record app values and the ARKit cross-check deltas (two independent detectors agreeing is method validation).
3. Calibrate on one dimension (e.g. width), then check the *other* dimensions against tape — held-out validation, not fitting to the answer.
4. Repeatability: reset, rescan 3–5×, compare spread to the displayed ±.
5. Unit tests (`PlaneMathTests`, 8 tests) prove the math: synthetic walls with 4 mm noise recover a known 0.686 m gap to < 1 mm, and a box covering 25% of the window doesn't drag the plane.

**Limitations (say them out loud):** world-scale error is the physical floor — 1/16″ over a closet span needs the calibration step; mirrors/glossy paint corrupt LiDAR (aim at a matte patch); walls out of plumb make "the" width location-dependent (we report the mean over the sampled patches + the angle); very dark closets need the torch for tracking.

## 20-minute demo script

1. **(2 min)** Problem framing: reach-in closet, cluttered, soffit, 1/16″ target — why edges/corners are the enemy and planes are the answer.
2. **(6 min)** Live scan: six captures → closet goes visibly empty on screen with dimensions on the wall. Point out σ/point-count feedback and a deliberate capture over a cluttered patch (warning fires, recapture).
3. **(3 min)** Door from outside: jambs + head chips → door width/height; note nothing else of the room was captured.
4. **(5 min)** Accuracy: tape vs app table, calibrate on width, validate on depth/height; show ARKit cross-check deltas and the repeatability spread.
5. **(4 min)** Architecture walkthrough (diagram above), why RoomPlan lost, limitations, Q&A.

## Build

Xcode project in `ClosetScanner/` — open, select your iPhone, Run (camera permission already configured). Tests: `xcodebuild -project ClosetScanner/ClosetScanner.xcodeproj -scheme ClosetScanner -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test`.
