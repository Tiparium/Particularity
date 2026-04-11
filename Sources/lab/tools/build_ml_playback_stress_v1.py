#!/usr/bin/env python3
"""Build a single-member 20k-particle binary stress fixture.

This intentionally uses only member_001 from raw_run_001. The goal is breadth
within one run, not mixing runs or seeds.
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
OUTPUT_DIR = LAB_ROOT / "data/derived/ml_playback_stress_v1"
OUTPUT_PATH = OUTPUT_DIR / "member_001_embedding_probe_20k.mlpb"
MAGIC = b"MLPBST1\0"
TARGET_PARTICLES = 20_000


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


def load_metrics_by_step(path: Path) -> dict[int, dict[str, float]]:
    metrics: dict[int, dict[str, float]] = {}
    with path.open("r", encoding="utf-8", newline="") as file:
        for row in csv.DictReader(file):
            step = int(row["step"])
            metrics[step] = {
                "train_acc": float(row["train_acc"]),
                "val_acc": float(row["val_acc"]),
                "train_loss": float(row["train_loss"]),
                "val_loss": float(row["val_loss"]),
            }
    return metrics


def token_coord(token: int) -> float:
    return (float(token) / 98.0) * 1.9 - 0.95


def dim_coord(dim: int, dim_count: int) -> float:
    return (float(dim) / max(1.0, float(dim_count - 1))) * 0.34 - 0.17


def squash(value: float, scale: float = 1.0) -> float:
    return math.tanh(value / scale)


def row_major(values: list[float], row: int, column: int, columns: int) -> float:
    return float(values[row * columns + column])


def probe_stage_value(values: list[float], stage: int, probe: int, dim: int) -> float:
    return float(values[((stage * 64 + probe) * 128) + dim])


def make_entities() -> list[tuple]:
    entities: list[tuple] = []

    for token in range(99):
        for dim in range(128):
            entities.append(("token_embed", token, dim))

    for token in range(99):
        for dim in range(68):
            entities.append(("unembed", token, dim))

    for position_id in range(4):
        for dim in range(128):
            entities.append(("pos_embed", position_id, dim))

    for probe_id in range(64):
        entities.append(("probe", probe_id, 0))

    for probe_id in range(20):
        entities.append(("answer_hidden", probe_id, 0))

    if len(entities) != TARGET_PARTICLES:
        raise ValueError(f"Expected {TARGET_PARTICLES} entities, got {len(entities)}")
    return entities


def build_record(entity, arrays, metrics, probe_metadata):
    kind, first, second = entity
    train_acc = metrics.get("train_acc", 0.0)
    val_acc = metrics.get("val_acc", 0.0)
    train_loss = metrics.get("train_loss", 0.0)
    val_loss = metrics.get("val_loss", 0.0)

    if kind == "token_embed":
        token, dim = first, second
        norm = row_major(arrays["token_embed_norm"], token, 0, 1)
        value = row_major(arrays["token_embed"], token, dim, 128)
        x = token_coord(token)
        y = -0.78 + dim_coord(dim, 128)
        z = squash(value, 1.25) * 0.86
        type_index = 0 if value < 0 else 1
        particle_id = token * 128 + dim
        sidecar = (value, norm, train_acc, float(dim), val_acc)
    elif kind == "unembed":
        token, dim = first, second
        norm = row_major(arrays["unembed_norm"], token, 0, 1)
        value = row_major(arrays["unembed"], token, dim, 128)
        x = token_coord(token)
        y = -0.20 + dim_coord(dim, 68)
        z = squash(value, 1.25) * 0.86
        type_index = 2 if value < 0 else 3
        particle_id = 20_000 + token * 128 + dim
        sidecar = (value, norm, val_acc, float(dim), train_acc)
    elif kind == "pos_embed":
        position_id, dim = first, second
        norm = row_major(arrays["pos_embed_norm"], position_id, 0, 1)
        value = row_major(arrays["pos_embed"], position_id, dim, 128)
        x = (float(position_id) / 3.0) * 1.2 - 0.6
        y = 0.35 + dim_coord(dim, 128)
        z = squash(value, 1.0) * 0.8
        type_index = 4 if value < 0 else 5
        particle_id = 40_000 + position_id * 128 + dim
        sidecar = (value, norm, float(position_id), train_loss, val_loss)
    elif kind == "probe":
        probe_id = first
        metadata = probe_metadata[probe_id]
        confidence = float(arrays["confidence"][probe_id])
        margin = float(arrays["margin"][probe_id])
        correct = int(arrays["correctness"][probe_id]) == 1
        split = metadata["split"]
        x = token_coord(int(metadata["x"]))
        y = token_coord(int(metadata["y"]))
        z = confidence * 1.75 - 0.88
        type_index = (6 if split == "train" else 8) + (1 if correct else 0)
        particle_id = 60_000 + probe_id
        sidecar = (
            confidence,
            margin,
            1.0 if correct else 0.0,
            float(arrays["predictions"][probe_id]),
            float(arrays["target_ids"][probe_id]),
        )
    else:
        probe_id, dim = first, second
        value = probe_stage_value(arrays["answer_hidden_by_stage"], 3, probe_id, dim)
        confidence = float(arrays["confidence"][probe_id])
        metadata = probe_metadata[probe_id]
        x = token_coord(int(metadata["x"]))
        y = 0.82 + dim_coord(dim, 20)
        z = squash(value, 1.1) * 0.82
        type_index = 10 if value < 0 else 11
        particle_id = 80_000 + probe_id * 128 + dim
        sidecar = (value, confidence, float(probe_id), train_acc, val_acc)

    return (
        float(max(-0.98, min(0.98, x))),
        float(max(-0.98, min(0.98, y))),
        float(max(-0.98, min(0.98, z))),
        int(type_index),
        int(particle_id),
        float(sidecar[0]),
        float(sidecar[1]),
        float(sidecar[2]),
        float(sidecar[3]),
        float(sidecar[4]),
    )


def main() -> None:
    with (RAW_MEMBER / "snapshots/index.json").open("r", encoding="utf-8") as file:
        entries = json.load(file)["entries"]
    with (RAW_MEMBER / "probe_metadata.json").open("r", encoding="utf-8") as file:
        probe_metadata = json.load(file)["probes"]

    metrics_by_step = load_metrics_by_step(RAW_MEMBER / "metrics.csv")
    entities = make_entities()
    duration_seconds = 52.0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with OUTPUT_PATH.open("wb") as file:
        file.write(MAGIC)
        file.write(struct.pack("<IId", len(entries), len(entities), duration_seconds))

        for entry in entries:
            step = int(entry["step"])
            time_seconds = 0.0 if step == 1 else float(step) / 1000.0
            embeddings_path = RAW_MEMBER / "snapshots" / entry["embeddings_file"]
            probes_path = RAW_MEMBER / "snapshots" / entry["probes_file"]
            arrays = {
                "token_embed": read_npy_from_npz(embeddings_path, "token_embed")[0],
                "token_embed_norm": read_npy_from_npz(embeddings_path, "token_embed_norm")[0],
                "unembed": read_npy_from_npz(embeddings_path, "unembed")[0],
                "unembed_norm": read_npy_from_npz(embeddings_path, "unembed_norm")[0],
                "pos_embed": read_npy_from_npz(embeddings_path, "pos_embed")[0],
                "pos_embed_norm": read_npy_from_npz(embeddings_path, "pos_embed_norm")[0],
                "answer_hidden_by_stage": read_npy_from_npz(probes_path, "answer_hidden_by_stage")[0],
                "predictions": read_npy_from_npz(probes_path, "predictions")[0],
                "target_ids": read_npy_from_npz(probes_path, "target_ids")[0],
                "correctness": read_npy_from_npz(probes_path, "correctness")[0],
                "confidence": read_npy_from_npz(probes_path, "confidence")[0],
                "margin": read_npy_from_npz(probes_path, "margin")[0],
            }
            metrics = metrics_by_step.get(step, {})

            file.write(struct.pack("<Id", step, time_seconds))
            for entity in entities:
                file.write(struct.pack("<fffIIfffff", *build_record(entity, arrays, metrics, probe_metadata)))

            print(f"wrote frame step={step}")

    print(f"Wrote {OUTPUT_PATH} with {len(entries)} frames and {len(entities)} particles")


if __name__ == "__main__":
    main()
