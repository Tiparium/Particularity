#!/usr/bin/env python3
"""Build a tiny real-data playback fixture from raw ML probe snapshots.

The raw data under data/raw is treated as read-only. This script writes a small
derived JSON fixture that the app prototype can load directly.
"""

from __future__ import annotations

import ast
import csv
import json
import math
import struct
import zipfile
from pathlib import Path


LAB_ROOT = Path(__file__).resolve().parents[1]
RAW_MEMBER = LAB_ROOT / "data/raw/raw_run_001/member_001"
OUTPUT_DIR = LAB_ROOT / "data/derived/ml_playback_v0"
OUTPUT_PATH = OUTPUT_DIR / "member_001_probe_playback.json"
MAX_PROBES = 64


def _read_npy_from_npz(npz_path: Path, array_name: str):
    with zipfile.ZipFile(npz_path) as archive:
        with archive.open(f"{array_name}.npy") as file:
            magic = file.read(6)
            if magic != b"\x93NUMPY":
                raise ValueError(f"{npz_path}:{array_name} is not an npy array")

            version = file.read(2)
            if version == b"\x01\x00":
                header_length = struct.unpack("<H", file.read(2))[0]
            elif version in (b"\x02\x00", b"\x03\x00"):
                header_length = struct.unpack("<I", file.read(4))[0]
            else:
                raise ValueError(f"Unsupported npy version {version!r}")

            header = ast.literal_eval(file.read(header_length).decode("latin1"))
            if header["fortran_order"]:
                raise ValueError(f"Fortran-order arrays are not supported: {npz_path}:{array_name}")

            dtype = header["descr"]
            shape = header["shape"]
            count = math.prod(shape)
            raw = file.read()

    if dtype == "<f4":
        values = list(struct.unpack(f"<{count}f", raw))
    elif dtype == "<i8":
        values = list(struct.unpack(f"<{count}q", raw))
    else:
        raise ValueError(f"Unsupported dtype {dtype} in {npz_path}:{array_name}")

    return values, shape


def _load_metrics_by_step(path: Path) -> dict[int, dict[str, float]]:
    metrics: dict[int, dict[str, float]] = {}
    with path.open("r", encoding="utf-8", newline="") as file:
        for row in csv.DictReader(file):
            step = int(row["step"])
            metrics[step] = {
                "train_loss": float(row["train_loss"]),
                "train_acc": float(row["train_acc"]),
                "val_loss": float(row["val_loss"]),
                "val_acc": float(row["val_acc"]),
            }
    return metrics


def _coordinate(value: int) -> float:
    return round((float(value) / 96.0) * 1.7 - 0.85, 5)


def _z_from_confidence(confidence: float, target: int) -> float:
    # Confidence carries the visible playback motion. The target term gives
    # otherwise-overlapping probes a stable depth offset.
    target_offset = ((float(target) / 96.0) - 0.5) * 0.34
    return round(max(-0.95, min(0.95, confidence * 1.55 - 0.78 + target_offset)), 5)


def main() -> None:
    with (RAW_MEMBER / "probe_metadata.json").open("r", encoding="utf-8") as file:
        probe_metadata = json.load(file)["probes"][:MAX_PROBES]

    with (RAW_MEMBER / "snapshots/index.json").open("r", encoding="utf-8") as file:
        snapshot_index = json.load(file)["entries"]

    metrics_by_step = _load_metrics_by_step(RAW_MEMBER / "metrics.csv")
    frames = []

    for entry in snapshot_index:
        step = int(entry["step"])
        probes_path = RAW_MEMBER / "snapshots" / entry["probes_file"]
        probe_ids, _ = _read_npy_from_npz(probes_path, "probe_ids")
        predictions, _ = _read_npy_from_npz(probes_path, "predictions")
        target_ids, _ = _read_npy_from_npz(probes_path, "target_ids")
        correctness, _ = _read_npy_from_npz(probes_path, "correctness")
        confidence, _ = _read_npy_from_npz(probes_path, "confidence")
        margin, _ = _read_npy_from_npz(probes_path, "margin")

        particles = []
        for particle_index, metadata in enumerate(probe_metadata):
            is_correct = int(correctness[particle_index]) == 1
            split = metadata["split"]
            type_index = (0 if split == "train" else 2) + (1 if is_correct else 0)
            conf = round(float(confidence[particle_index]), 5)
            target = int(target_ids[particle_index])

            particles.append(
                {
                    "id": int(probe_ids[particle_index]),
                    "equation": metadata["equation"],
                    "split": split,
                    "position": [
                        _coordinate(int(metadata["x"])),
                        _coordinate(int(metadata["y"])),
                        _z_from_confidence(conf, target),
                    ],
                    "type": type_index,
                    "sidecar": {
                        "confidence": conf,
                        "margin": round(float(margin[particle_index]), 5),
                        "correctness": 1 if is_correct else 0,
                        "prediction": int(predictions[particle_index]),
                        "target": target,
                    },
                }
            )

        frame_metrics = metrics_by_step.get(step, {})
        frames.append(
            {
                "step": step,
                "timeSeconds": 0.0 if step == 1 else float(step) / 1000.0,
                "metrics": frame_metrics,
                "particles": particles,
            }
        )

    fixture = {
        "schema": "ml_playback_v0",
        "source": {
            "raw_member": "data/raw/raw_run_001/member_001",
            "note": "Tiny derived playback fixture. Raw data remains read-only.",
        },
        "particleCount": len(probe_metadata),
        "typeLegend": [
            "train_incorrect",
            "train_correct",
            "validation_incorrect",
            "validation_correct",
        ],
        "durationSeconds": frames[-1]["timeSeconds"] if frames else 0.0,
        "frames": frames,
    }

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with OUTPUT_PATH.open("w", encoding="utf-8") as file:
        json.dump(fixture, file, separators=(",", ":"))
        file.write("\n")

    print(f"Wrote {OUTPUT_PATH} with {len(frames)} frames and {len(probe_metadata)} particles")


if __name__ == "__main__":
    main()
