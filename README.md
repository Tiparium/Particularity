# Particularity

Particularity is a native macOS particle simulation and playback sandbox built around modular simulation workflows, GPU rendering, and interactive visual debugging.

The project is currently experimental. It is not a polished end-user release, but it is far enough along to demonstrate the core direction: realtime particle simulations and prebaked playback visualizations running through the same high-level module model.

## What It Does

Particularity provides an interactive viewport for exploring particle-based systems. Current work focuses on two execution styles:

- **Realtime simulation**: particles are advanced live through simulation modules.
- **Playback simulation**: prebaked or recorded data is read and presented through the same runtime shell.

The app currently includes:

- A default realtime particle simulation.
- A Type Matrix simulation presented as **Primordial Soup v0.1**.
- A toy playback Trinity used to validate the playback runtime.
- An ML training playback Trinity that renders selected training data as animated surface meshes.
- A Z-up 3D viewport with orbit/navigation camera controls and an axis compass.
- Dockable settings/debug panels for runtime inspection and module configuration.

## Core Model

Particularity is organized around **Trinities**: grouped module sets that describe a complete simulation or playback workflow.

Each Trinity is made from three functional stages:

- **Producer**: provides source data or initial simulation state.
- **Processor**: advances, transforms, or interprets that data.
- **Presenter**: renders or exposes the result visually.

This replaces the older Optimization / Physics / Visual terminology with a more general model that works for both realtime simulations and prebaked playback.

Modules expose their settings through JSON manifests. The app reads those schemas and builds generic settings panels from them, so module-specific controls do not need to be hardcoded into the main UI.

## Current Status

This repository is under active development. Expect internal APIs, module boundaries, and UI conventions to continue changing.

Recent architectural work includes:

- A first-class playback runtime.
- Trinity-based module selection.
- Schema-driven module settings.
- A Z-up camera and world model.
- ML playback surface mesh rendering.

The project is best understood as a working prototype of the engine/editor direction rather than a stable application release.

## Requirements

- macOS 14 or newer.
- Xcode / Xcode command line tools with Swift 6.2 support.
- A Metal-capable Mac.

The project is a Swift Package executable target and links against SwiftUI, AppKit, Metal, MetalKit, and QuartzCore.

## Setup

Clone the repository, then run:

```sh
./run selfcheck
```

If selfcheck reports a failure, see [Troubleshooting](#troubleshooting).

If the Metal toolchain component is missing, run:

```sh
./run setup
```

Build the app:

```sh
./run build
```

Run tests:

```sh
./run test
```

Launch the app:

```sh
./run particles
```

## Repository Layout

```text
Modules/                 Module manifests and module-owned shader/source assets.
Sources/Physics_Sim/     Main Swift, Metal, runtime, renderer, and UI source.
Sources/Physics_Sim/Shaders/
                         Packaged Metal shader sources.
Tests/                   Swift test suite.
.run_rsc/                Helper scripts used by the ./run command.
run                      Project command router.
Package.swift            Swift Package definition.
```

Local/generated data and machine-specific project metadata are intentionally ignored. In particular, `Sources/lab/`, `.build/`, `.vscode/`, `.harbormaster/`, and similar local state are not part of the public project surface.

## Troubleshooting

`./run selfcheck` verifies the local tools needed to build and run Particularity. Treat `[FAIL]` items as blockers. `[WARN]` items may be worth fixing, but do not always prevent the project from running.

Common selfcheck failures:

- **Git missing**: install Git or Xcode command line tools.
- **Xcode build tools missing**: install Xcode from the App Store or Apple Developer downloads.
- **Xcode runtime tools missing**: install Xcode command line tools and make sure `xcrun` is available.
- **Swift toolchain missing**: install Xcode with Swift support.
- **xcodebuild not ready**: open Xcode once and accept any first-run prompts or license agreements.
- **Metal toolchain missing**: run `./run setup`, then rerun `./run selfcheck`.

Common selfcheck warnings:

- **xcode-select does not point to full Xcode**: if builds fail, switch to full Xcode with:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

- **Homebrew missing**: Homebrew is optional for the current setup path, but may be useful for additional development tooling.

## License

License information has not been added yet.
