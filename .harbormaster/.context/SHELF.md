## Shelf

### Immediate Shelf
0) Investigate and likely remove CPU-side writes into the live particle buffer after the GPU queue-ordering/render-sync work is resolved.
1) Audit EventuallyApplied controls for sticky/rubber-banding behavior. Several playback settings controls can feel delayed or snap back to unexpected values during active interaction; likely related to deferred commits colliding with external state refreshes.
2) #
3) #
4) #
5) #
6) #
7) #
8) #
9) #

### Top Shelf
0) Fix panel drag session regression: no zone highlight,
   no drop preview, and no successful drop commit.
1) Rework module loading/assignment/selection architecture. Current module selection is too janky: assignment, discovery, compatibility, fallback behavior, UI reporting, and mode-aware validation need a cleaner design before the module system gets much more complex. This likely belongs near the first-class playback-mode pass, because realtime and playback modules should not be selected through the same brittle fake-trio assumptions forever.
2) Full playback-mode refactor. Refactor the ML playback prototype out of shared core paths into a native first-class playback mode with its own module contract/family. Current prototype touches generic runtime/renderer/state files; once behavior stabilizes, move playback-specific logic behind modular playback interfaces, keep specialized ML/dataset code out of core files, and restore clean separation for realtime simulation paths.

### Middle Shelf
0) Split oversized `ContentView.swift` UI/state ownership into narrower app-shell subroles once engine/session entanglement work is stable.

### Bottom Shelf

### Long Term
0) Explore multi-window support for Particularity using macOS-style app behavior.
1) Explore a tabbed workspace system for managing multiple simulation views/configurations.
2) Decouple simulation orchestration from the main actor/UI lane so simulation scheduling can evolve independently of the app shell.

### Completed
