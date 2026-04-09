# Sprint 01 Report

Date: 2026-04-01
Sprint branch: `sprint_01`

## Outcomes delivered

1. Inter-module runtime handoff was made real between optimization, physics, and visual.
- Runtime now owns a canonical particle buffer instead of separate position/color-only render state.
- Optimization now materializes `interactionOffsets` and `interactionIndices`.
- Physics consumes optimization-supplied particle indices instead of relying on implicit all-pairs traversal.
- Visual derives particle appearance from particle type rather than canonical stored color.

2. The default module path was preserved while moving to the new contract.
- Default optimization still provides the naive all-pairs interaction set.
- Default physics still behaves as slide-and-loop motion only.
- Default physics now participates in the new handoff path without adding inter-particle impulse.

3. Simulation lifecycle behavior was corrected to match transport expectations.
- Pause/play preserves live simulation state.
- Stop/start fully resets particle state back to canonical spawn.
- Launch failure handling was reworked so the app reports startup errors instead of hard-crashing.

4. First-pass support for a full matrix-driven physics module was added.
- Added `TypeMatrixLocalAttractionRepulsion` Metal kernels for phase-1 impulse accumulation and phase-2 application.
- Interaction behavior is driven by a type matrix plus `innerRadius`, `middleRadius`, and `outerRadius`.
- Phase 1 iterates only optimization-supplied indices, uses normalized direction vectors, and now averages impulse over only the candidates inside the full effect radius.
- Phase 2 applies accumulated impulse back to the current particle only, preserving one-sided self-owned writes.

5. Physics-module-local settings support was introduced.
- Added a persistent module-settings store separate from particle schema and inter-module contracts.
- Added first-pass persisted settings for the type-matrix physics module radii and matrix regeneration nonce.
- Added settings panel wiring so active-module settings can appear in the shared settings UI.

6. First-pass type-matrix workflow support was added to the UI/runtime path.
- Added a dedicated settings panel for the type-matrix physics module.
- The panel now exposes radii controls in centimeters, module-specific particle-type cap messaging, startup randomization control, matrix regeneration, and direct matrix editing.
- The first pass now treats the simulation domain as a 1 meter cube and maps interaction radii from UI centimeters into simulation world units.
- The stored matrix is now editable canonical module-local state, while startup randomization can swap in a randomized runtime copy without overwriting the stored matrix.

7. The type-matrix settings path was opened up for live runtime tuning.
- Added matrix minimum and maximum parameters that control regeneration range and constrain live editing.
- Added global attraction and repulsion multipliers for positive and negative interactions respectively.
- Matrix regeneration and direct cell editing now remain enabled while the simulation is running.
- Runtime updates to the canonical matrix now immediately replace the active GPU matrix buffer for the running type-matrix simulation.

8. High-frequency UI state churn was reduced in the viewport and slider paths.
- `EventuallyAppliedSlider` and `EventuallyAppliedIntSlider` now use local draft values plus deferred commit instead of applying every drag tick directly into shared editor state.
- Camera motion now runs against renderer-local live state and commits back to the shared viewport store on a short debounce, with explicit flush on interaction end.
- This preserves eventual persistence while removing the worst real-time shared-state publication cost during camera orbit and slider scrubbing.

9. Camera persistence was separated from the heavier workspace snapshot path.
- Camera state now persists through its own lightweight store instead of forcing the full workspace snapshot path to carry every orbit update.
- Interaction-end camera flush was removed so orbiting no longer pays a forced shared-state sync penalty at mouse-up.
- The viewport input path now only tracks indirect touches for `clickThenDrag`, reducing the chance of spurious hover/touch activity feeding camera interaction state.

## Validation performed

1. `swift build` completed successfully after the type-matrix module and settings-store integration.

2. `./run particles` completed successfully and reached `[PASS] Launching UI`.

3. The shared Metal library compiled at app startup with both the default physics shaders and the new type-matrix physics shaders present.

4. `swift build` completed successfully after adding centimeter-based scaling, matrix editing UI, canonical matrix persistence, and startup-randomization toggle support.

5. `./run particles` completed successfully after the matrix editor and scale changes and again reached `[PASS] Launching UI`.

6. `swift build` completed successfully after adding live matrix regeneration/editing, matrix min/max controls, and attraction/repulsion interaction multipliers.

7. `swift build` completed successfully after the formal UI/camera debounce changes.

8. `./run particles` still reaches `[PASS] Launching UI` after the debounce changes.

9. `swift build` completed successfully after the camera-persistence split and viewport input tightening.

10. `./run particles` still reaches `[PASS] Launching UI` after the camera-persistence split.

## Final sprint state

- Sprint 01 is in progress.
- The first-pass matrix-driven physics module path is wired into the application, but further iteration is still needed on module behavior, UI refinement, and follow-on sprint features.
