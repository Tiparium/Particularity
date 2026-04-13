#!/usr/bin/env python3
"""Build a 15-neuron layered playback fixture from e_08 run_001 neuron sweeps.

Layout:
- 3 layers (front/middle/final) x 5 selected neurons each
- each layer/slot stores a full x/y activation surface
- records are grouped by (layer, slot, x, y) so renderer can draw per-surface meshes
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
INPUT_DIR = REPO_ROOT / "Sources/lab/data/raw/e_08_run_001/member_001/derived/neuron_sweeps"
MANIFEST_PATH = INPUT_DIR / "manifest.json"
OUTPUT_DIR = REPO_ROOT / "Sources/lab/data/derived/ml_playback_neuron_sweeps_v3"
OUTPUT_PATH = OUTPUT_DIR / "e08_run001_layers15.mlpb"
MAGIC = b"MLPBST1\0"
TARGET_FRAME_COUNT = 180
TARGET_GRID_SIDE = 80

# Chosen from final checkpoint top periodicity_score per layer.
SELECTED_NEURONS_BY_LAYER = {
    0: [163, 71, 64, 156, 83],   # front
    1: [81, 28, 67, 32, 124],    # middle
    2: [42, 14, 169, 16, 155],   # final
}


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
    return float(value - minimum) / float(denominator)


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


def bin_bounds(source_count: int, target_count: int, target_index: int) -> tuple[int, int]:
    start = int(math.floor(target_index * source_count / target_count))
    end = int(math.floor((target_index + 1) * source_count / target_count))
    return start, max(start + 1, end)


def main() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    entries = sorted(
        (entry for entry in manifest["entries"] if str(entry["file"]).endswith(".npz")),
        key=lambda item: int(item["step"]),
    )
    entries = [entry for entry in entries if (INPUT_DIR / entry["file"]).exists()]
    if not entries:
        raise ValueError("No sweep entries found in manifest.")

    selected_entries = sampled_entries(entries, TARGET_FRAME_COUNT)

    first_file = INPUT_DIR / selected_entries[0]["file"]
    x_values, x_shape = read_npy_from_npz(first_file, "x_values")
    y_values, y_shape = read_npy_from_npz(first_file, "y_values")
    first_mlp_post, first_shape = read_npy_from_npz(first_file, "mlp_post_activation")
    if len(x_shape) != 1 or len(y_shape) != 1:
        raise ValueError("x_values and y_values must be rank-1 arrays.")
    if len(first_shape) != 4:
        raise ValueError(f"Unexpected first mlp_post_activation rank: {first_shape}")

    layer_count, x_count, y_count, neuron_count = first_shape
    selected_map: dict[int, list[int]] = {}
    for layer in range(3):
        layer_neurons = SELECTED_NEURONS_BY_LAYER[layer]
        selected_map[layer] = [min(max(0, neuron), neuron_count - 1) for neuron in layer_neurons]

    x_min = int(min(x_values))
    x_max = int(max(x_values))
    y_min = int(min(y_values))
    y_max = int(max(y_values))
    surfaces_per_frame = 3 * 5
    output_x_count = min(TARGET_GRID_SIDE, x_count)
    output_y_count = min(TARGET_GRID_SIDE, y_count)
    surface_particle_count = output_x_count * output_y_count
    particle_count = surface_particle_count * surfaces_per_frame
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

            time_seconds = 0.0 if step == 1 else float(step) / 1000.0
            file.write(struct.pack("<Id", step, time_seconds))

            for layer in range(3):
                for slot, neuron in enumerate(selected_map[layer]):
                    periodicity = float(periodicity_scores[layer * neuron_count + neuron])
                    for output_x_index in range(output_x_count):
                        x_start, x_end = bin_bounds(x_count, output_x_count, output_x_index)
                        x_token = sum(int(x_values[index]) for index in range(x_start, x_end)) / float(x_end - x_start)
                        x_norm = normalize_unit(x_token, x_min, x_max)
                        x_position = x_norm * 1.9 - 0.95

                        for output_y_index in range(output_y_count):
                            y_start, y_end = bin_bounds(y_count, output_y_count, output_y_index)
                            y_token = sum(int(y_values[index]) for index in range(y_start, y_end)) / float(y_end - y_start)
                            y_norm = normalize_unit(y_token, y_min, y_max)
                            y_position = y_norm * 1.9 - 0.95

                            activation_sum = 0.0
                            activation_count = 0
                            for source_x_index in range(x_start, x_end):
                                for source_y_index in range(y_start, y_end):
                                    activation_sum += index4(
                                        mlp_post,
                                        layer,
                                        source_x_index,
                                        source_y_index,
                                        neuron,
                                        x_count,
                                        y_count,
                                        neuron_count,
                                    )
                                    activation_count += 1
                            activation = activation_sum / float(max(1, activation_count))
                            z_position = squash(activation) * 0.72

                            source_center_x = min(x_count - 1, (x_start + x_end) // 2)
                            source_center_y = min(y_count - 1, (y_start + y_end) // 2)
                            source_target_index = source_center_x * y_count + source_center_y
                            target_index = output_x_index * output_y_count + output_y_index
                            target = int(targets[source_target_index])
                            target_norm = normalize_unit(target, y_min, y_max)
                            type_index = slot  # slot index is consumed by playback renderer
                            particle_id = (
                                ((layer * 5 + slot) * surface_particle_count) + target_index
                            )
                            activation_norm = (z_position / 0.72 + 1.0) * 0.5

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
                                    float(layer),
                                )
                            )

    print(
        "Built layered neuron-sweep fixture:",
        OUTPUT_PATH,
        f"(frames={len(selected_entries)} particles={particle_count} surface_particles={surface_particle_count})",
    )
    print("Selected neurons by layer:", selected_map)


if __name__ == "__main__":
    main()
