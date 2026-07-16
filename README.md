# ClosetScanner

An iPhone app that measures reach-in closets with the LiDAR sensor. Each surface is captured as a plane fitted to tens of thousands of depth samples, and dimensions are computed as plane-to-plane distances — so a cluttered closet measures correctly even when its corners and edges are hidden behind cabinets or boxes. Once the interior is captured, the app draws the closet empty: an opaque, clean-rendered shell over the live camera feed, plus a rotatable 3D model.

Built with SwiftUI, ARKit, and RealityKit. No third-party dependencies. Requires an iPhone with LiDAR (Pro models).

## Using the app

1. The start screen asks whether the closet has a soffit. That sets the capture order: soffit → door → interior.
2. For each step, aim the on-screen reticle at a bare patch of the named surface and tap capture, holding still for about a second. Any visible patch works; the app never needs to see an edge or corner.
3. The door is captured from outside — both jambs and the head. Only what's inside the reticle is ever sampled, so the rest of the room stays out of the scan.
4. After the six interior surfaces (left, right, back, front, floor, ceiling), the closet renders empty with W/D/H drawn on the back wall. "3D view" opens an orbitable model of the empty space.
5. Tap any measurement to calibrate: enter the tape-measured value and a scale correction is applied to all measurements and persisted.

A torch button is in the top bar — closets are dark, and while LiDAR doesn't need light, camera tracking does.

## How it works

Each capture accumulates the central window of the LiDAR depth map over 40 frames, keeping only high-confidence pixels, and unprojects them through the camera intrinsics into world space — typically 50–150k points. A plane is fitted in two passes: trimmed least squares (the worst 25% of residuals dropped), then re-admission of every point within a MAD-based band around the trimmed fit. This keeps a hanger or box edge clipping the window from dragging the plane. The fit reports its residual σ and inlier fraction, and the app warns when a capture looks cluttered, uneven, or has the wrong orientation for the surface it's supposed to be.

A dimension is the symmetrized mean distance between the sample points of one plane and the fitted plane of its opposite. The wall-to-wall angle is checked and shown when the pair is more than 1.5° out of parallel. Corners for the rendered shell come from three-plane intersections; the shell quads are textured procedurally and drawn without occlusion, which is what makes the real contents disappear.

Every capture also raycasts against ARKit's independent plane detection. Each measurement row shows the difference between the two estimators as a built-in cross-check.

I tried Apple RoomPlan first (that attempt is on `main`). It's designed for whole rooms, needs more standoff distance than a 24-inch-deep closet allows, loses walls behind clutter, and models the entire bedroom when you scan the door from outside. The plane-fitting approach replaced it.

## Accuracy

With ~10⁵ samples per surface, averaging pushes the statistical error well under a millimeter; what remains is systematic. The dominant term is ARKit's world-scale error, typically 0.3–0.5% of the span — about 1/8″ across a closet. The calibration step exists for exactly this: one tape-measured reference brings the scale term down to roughly 0.15%, which is 1/16″ territory on typical closet spans. Every measurement displays its own ± (standard error combined with the scale term, floored at 1/32″) rather than implying more precision than the sensor supports.

## Validation

- Unit tests cover the geometry: synthetic walls with 4 mm of noise recover a known 0.686 m gap to under 1 mm, and a simulated box covering a quarter of the sampling window does not move the fitted plane.
- Tape-measure protocol: calibrate on one dimension, then compare the remaining dimensions against tape. Held-out checks, not fitting to the answer.
- Repeatability: rescan the same closet several times and compare the spread against the displayed ±.
- Method agreement: the ARKit cross-check on each row is a second, independent detector; the two agreeing is evidence neither is broken.

## Limitations

- The 1/16″ target needs the calibration step; uncalibrated, world-scale drift caps accuracy around 1/8″ on typical spans.
- Mirrors and glossy paint corrupt LiDAR returns — aim at matte patches.
- Real walls are not perfectly plumb or parallel. The app reports the mean gap over the sampled patches and flags the angle; where you sample is part of what "the" width means.
- Door height needs the floor plane, which is captured in the interior phase, so it appears late in the flow.

## Building and testing

Open `ClosetScanner/ClosetScanner.xcodeproj` in Xcode, select an iPhone with LiDAR, and run. Camera permission is already configured.

```
xcodebuild -project ClosetScanner/ClosetScanner.xcodeproj -scheme ClosetScanner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

Source layout: `PlaneMath.swift` (geometry and formatting, no ARKit imports, unit-tested), `CaptureController.swift` (session, capture, measurements, rendering), `ScanView.swift` / `StartView.swift` (UI).
