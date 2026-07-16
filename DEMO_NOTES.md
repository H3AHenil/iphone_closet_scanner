# Closet Scanner demo notes

This is the longer reference sheet for the live walkthrough. Keep the public-facing explanation in `README.md`.

## Before the demo

- Use a charged LiDAR-equipped iPhone and clean the camera/LiDAR glass.
- Measure width, depth, and height with a tape at the same areas the app will sample.
- Test the torch, camera permission, calibration reset, and the 3D viewer.
- Do one complete practice scan in the demo closet and save a few screenshots as a fallback.
- Prefer matte, bare patches. Avoid mirrors, glossy hardware, clothing, and shelf edges inside the reticle.

## Suggested walkthrough (10–12 minutes)

1. Start with the constraint: a full closet cannot be measured reliably by finding visible corners because the corners are usually obstructed.
2. On the start screen, answer whether the closet has a soffit. Explain that this changes the capture sequence rather than asking the user to skip irrelevant steps.
3. If present, capture the soffit underside and face from inside the closet.
4. Step outside and capture the left jamb, right jamb, and door head.
5. Move inside and capture the left, right, back, and front walls, followed by the floor and ceiling. Hold still while the progress ring fills.
6. Point out the sample count and residual sigma after a capture. Recapture if the app flags clutter, poor flatness, or the wrong orientation.
7. Once the six interior planes are complete, show the clean shell in AR and open the orbitable 3D view.
8. Compare the results with the tape measurements. Calibrate with one known dimension, then use the other dimensions as held-out checks.

## How to explain the approach

The app samples high-confidence LiDAR depth only inside the reticle for about 40 frames. It converts those pixels into world-space points, rejects outliers, and fits a plane to the remaining surface. Dimensions are calculated as plane-to-plane distances, so a box or hanging clothes can obscure an edge without changing the result as long as a clean patch of each surface is visible.

ARKit plane raycasts provide an independent cross-check. They are not used to produce the primary measurement. Agreement between the fitted plane and ARKit is a useful signal that the capture is sound.

The rendering uses the intersections of the fitted wall, floor, and ceiling planes. Procedural wall and floor materials keep the reconstructed closet readable even when the real closet is dark, and the secondary viewer centers and scales the same geometry for orbit and zoom controls.

## Accuracy talking points

- Averaging many depth samples makes random per-pixel noise small; world-scale drift is the dominant remaining error.
- Before calibration, a realistic expectation is around 1/8 inch over typical closet spans.
- A tape-measured calibration reference corrects the global scale. The 1/16-inch target assumes good surfaces, stable tracking, and calibration.
- Each row displays an uncertainty estimate. The app does not claim that every sixteenth shown by formatting is equally certain.
- Out-of-parallel or out-of-plumb walls are real geometry, not sensor noise. The app reports the sampled plane gap and flags angular disagreement.

## Why not RoomPlan?

RoomPlan is optimized for room-scale capture. A reach-in closet provides little standoff distance, clutter hides structural edges, and scanning its door from outside can pull the surrounding bedroom into the model. Fitting user-selected planes keeps the capture scoped to the surfaces that define the closet.

## Recovery during a live scan

- Tracking limited: move slowly and let the phone re-establish features.
- Closet too dark: turn on the torch.
- Too few points: move closer while keeping a flat patch inside the reticle.
- High sigma or low inlier percentage: choose a barer patch and recapture.
- Wrong vertical/horizontal warning: check that the intended surface fills the reticle.
- Shell looks twisted: recapture the plane with the largest angle warning, or reset and repeat with slower movement.

## Likely questions

**Why capture several frames?** A single depth image is noisy. Multiple frames add many observations and make robust outlier rejection more effective.

**Why does door height appear later?** The door head is captured during the door phase, but its height is the distance to the floor plane, which is collected during the interior phase.

**What does calibration change?** It applies one scale factor to every fitted distance. It does not move or rotate individual planes.

**What would come next?** Persist scans, export a dimensioned model, add a guided validation mode, and test the workflow across a larger set of closet shapes and surface finishes.
