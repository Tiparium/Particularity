#!/usr/bin/env python3
"""Build a playback fixture from e_08 run_001 neuron sweeps.

This targets one concrete run first (run_001) and chooses a stable high-periodicity
neuron from the manifest tail to maximize visible grokking structure.
"""

from __future__ import annotations

import ast
import json
import math
import struct
import zipfile
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parents[2]
INPUT_DIR = REPO_ROOT / "Sources/lab/data/raw/e_08_run_001/derived/neuron_sweeps"
MANIFEST_PATH = INPUT_DIR / "manifest.json"
OUTPUT_DIR = REPO_ROOT / "Sources/lab/data/derived/ml_playback_neuron_sweeps_v2"
OUTPUT_PATH = OUTPUT_DIR / "e08_run001_layer2_neuron185.mlpb"
MAGIC = b"MLPBST1\0"
TARGET_FRAME_COUNT = 220


def read_npy_from_npz(npz_path: Path, array_name: str):
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
        return list(struct.unpack(f"<{count}f", raw)), shape
    if dtype == "<i8":
        return list(struct.unpack(f"<{count}q", raw)), shape
    raise ValueError(f"Unsupported dtype {dtype} in {npz_path}:{array_name}")


def index4(values: list[float], a: int, b: int, c: int, d: int, b_count: int, c_count: int, d_count: int) -> float:
    index = (((a * b_count + b) * c_count + c) * d_count) + d
    return float(values[index])


def normalize_unit(value: int, minimum: int, maximum: int) -> float:
    denominator = max(1, maximum - minimum)
    return (float(value - minimum) / float(denominator))


def squash(value: float, scale: float = 3.0) -> float:
    return math.tanh(value / scale)


def sampled_entries(entries: list[dict], target_count: int) -> list[dict]:
    if len(entries) <= target_count:
        return entries
    last = len(entries) - 1
    chosen = {0, last}
    for i in range(target_count - 2):
        position = round((i + 1) * last / (target_count - 1))
        chosen.add(position)
    return [entries[i] for i in sorted(chosen)]


def main() -> None:
    with MANIFEST_PATH.open("r", encoding="utf-8") as file:
        manifest = json.load(file)
    entries = sorted(
        (entry for entry in manifest["entries"] if str(entry["file"]).endswith(".npz")),
        key=lambda item: int(item["step"]),
    )
    entries = [entry for entry in entries if (INPUT_DIR / entry["file"]).exists()]
    if not entries:
        raise ValueError("No sweep entries found in manifest.")

    selected_entries = sampled_entries(entries, TARGET_FRAME_COUNT)
    tail_entry = entries[-1]
    selected_layer = int(tail_entry.get("best_layer", 2))
    selected_neuron = int(tail_entry.get("best_neuron", 185))

    first_file = INPUT_DIR / selected_entries[0]["file"]
    x_values, x_shape = read_npy_from_npz(first_file, "x_values")
    y_values, y_shape = read_npy_from_npz(first_file, "y_values")
    first_mlp_post, first_shape = read_npy_from_npz(first_file, "mlp_post_activation")
    if len(x_shape) != 1 or len(y_shape) != 1:
        raise ValueError("x_values and y_values must be rank-1 arrays.")
    if len(first_shape) != 4:
        raise ValueError(f"Unexpected first mlp_post_activation rank: {first_shape}")
    x_count = x_shape[0]
    y_count = y_shape[0]
    layer_count = first_shape[0]
    neuron_count = first_shape[3]
    selected_layer = min(max(0, selected_layer), layer_count - 1)
    selected_neuron = min(max(0, selected_neuron), neuron_count - 1)

    x_min = int(min(x_values))
    x_max = int(max(x_values))
    y_min = int(min(y_values))
    y_max = int(max(y_values))
    particle_count = x_count * y_count
    duration_seconds = float(max(int(entry["step"]) for entry in selected_entries)) / 1000.0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with OUTPUT_PATH.open("wb") as file:
        file.write(MAGIC)
        file.write(struct.pack("<IId", len(selected_entries), particle_count, duration_seconds))

        for entry in selected_entries:
            step = int(entry["step"])
            npz_path = INPUT_DIR / entry["file"]
            mlp_post, shape = read_npy_from_npz(npz_path, "mlp_post_activation")
            targets, targets_shape = read_npy_from_npz(npz_path, "targets")
            periodicity_scores, periodicity_shape = read_npy_from_npz(npz_path, "periodicity_score")

            if shape != (layer_count, x_count, y_count, neuron_count):
                raise ValueError(f"Unexpected mlp_post_activation shape in {npz_path}: {shape}")
            if targets_shape != (x_count, y_count):
                raise ValueError(f"Unexpected targets shape in {npz_path}: {targets_shape}")
            if periodicity_shape != (layer_count, neuron_count):
                raise ValueError(f"Unexpected periodicity_score shape in {npz_path}: {periodicity_shape}")

            periodicity = float(periodicity_scores[selected_layer * neuron_count + selected_neuron])
            time_seconds = 0.0 if step == 1 else float(step) / 1000.0
            file.write(struct.pack("<Id", step, time_seconds))

            for x_index in range(x_count):
                x_token = int(x_values[x_index])
                x_norm = normalize_unit(x_token, x_min, x_max)
                x_position = x_norm * 1.9 - 0.95

                for y_index in range(y_count):
                    y_token = int(y_values[y_index])
                    y_norm = normalize_unit(y_token, y_min, y_max)
                    y_position = y_norm * 1.9 - 0.95

                    activation = index4(
                        mlp_post,
                        selected_layer,
                        x_index,
                        y_index,
                        selected_neuron,
                        x_count,
                        y_count,
                        neuron_count,
                    )
                    z_position = squash(activation) * 0.86

                    target_index = x_index * y_count + y_index
                    target = int(targets[target_index])
                    target_norm = normalize_unit(target, y_min, y_max)
                    type_index = target % 12
                    particle_id = x_index * y_count + y_index
                    activation_norm = (z_position / 0.86 + 1.0) * 0.5

                    file.write(
                        struct.pack(
                            "<fffIIfffff",
                            float(max(-0.98, min(0.98, x_position))),
                            float(max(-0.98, min(0.98, y_position))),
                            float(max(-0.98, min(0.98, z_position))),
                            type_index,
                            particle_id,
                            float(activation),
                            float(max(0.0, min(1.0, activation_norm))),
                            float(max(0.0, min(1.0, periodicity))),
                            float(max(0.0, min(1.0, target_norm))),
                            float(x_norm),
                        )
                    )

    print(
        "Built e_08 run_001 neuron-sweep fixture:",
        OUTPUT_PATH,
        f"(frames={len(selected_entries)} particles={particle_count} layer={selected_layer} neuron={selected_neuron})",
    )


if __name__ == "__main__":
    main()
