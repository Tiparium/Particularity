## Shelf

### Immediate Shelf
0) UI state system refactor
   - Replace ad hoc control-color decisions with a semantic state model.
   - Define canonical control meanings such as `neutral`, `active`, `disabled`, and `destructive`.
   - Unify normal control-state rendering with invalid/warning validation highlighting so they stop acting like separate overlapping systems.
   - Make controls derive visual treatment from semantic state rather than choosing colors directly.
   - Audit the existing UI controls and remap them to the shared state model.
1) Full Z-up world refactor
   - Migrate renderer, camera, viewport, and simulation-space assumptions from the current Y-up behavior to the intended Z-up model.
   - Make X/Y the horizontal plane and Z the true vertical axis across the actual engine/runtime, not just in UI translation layers.
   - Remove the temporary compass-only axis correction after the world model is truly Z-up.
   - Revisit camera movement, orbit rules, reset logic, and any module/runtime math that currently assumes the old orientation.
2) #
3) #
4) #
5) #
6) #
7) #
8) #
9) #

### Top Shelf

### Middle Shelf
0) Split oversized `ContentView.swift` UI/state ownership into narrower app-shell subroles once engine/session entanglement work is stable.

### Bottom Shelf

### Long Term
0) Explore multi-window support for Particularity using macOS-style app behavior.
1) Explore a tabbed workspace system for managing multiple simulation views/configurations.
2) Decouple simulation orchestration from the main actor/UI lane so simulation scheduling can evolve independently of the app shell.

### Completed
0) Investigate and likely remove CPU-side writes into the live particle buffer after the GPU queue-ordering/render-sync work is resolved.
   - Moved out of active shelf per current project state and user direction.
1) Fix panel drag session regression: no zone highlight,
   no drop preview, and no successful drop commit.
   - Addressed in the current UI/panel work and no longer needs top-shelf status.
