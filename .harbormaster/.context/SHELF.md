## Shelf

### Immediate Shelf
0) Investigate and likely remove CPU-side writes into the live particle buffer after the GPU queue-ordering/render-sync work is resolved.
1) #
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
1) Rework module loading/assignment architecture. Current module loading is too janky: assignment, discovery, compatibility, fallback behavior, and UI reporting need a cleaner design before the module system gets much more complex.

### Middle Shelf
0) Split oversized `ContentView.swift` UI/state ownership into narrower app-shell subroles once engine/session entanglement work is stable.

### Bottom Shelf

### Long Term
0) Explore multi-window support for Particularity using macOS-style app behavior.
1) Explore a tabbed workspace system for managing multiple simulation views/configurations.
2) Decouple simulation orchestration from the main actor/UI lane so simulation scheduling can evolve independently of the app shell.

### Completed
