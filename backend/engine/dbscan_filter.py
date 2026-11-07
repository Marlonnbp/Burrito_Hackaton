"""Filtro anti-trolls con DBSCAN sobre el circuito 1D.

El loop es circular, así que cada distance_m se embebe en un círculo de
perímetro L (x = R cos θ, y = R sin θ, R = L / 2π): la cuerda ≈ arco para
eps pequeños y los reportes a ambos lados del origen quedan juntos.
La reputación del usuario actúa como sample_weight.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from sklearn.cluster import DBSCAN


@dataclass
class ClusterResult:
    center_m: float | None          # centroide circular del cluster ganador
    valid_mask: list[bool]          # True = reporte aceptado
    confidence: float               # 0..1
    n_valid: int
    n_rejected: int


def filter_reports(distances_m: list[float], reputations: list[float], loop_length_m: float,
                   eps_m: float = 60.0, min_weight: int = 2) -> ClusterResult:
    n = len(distances_m)
    if n == 0:
        return ClusterResult(None, [], 0.0, 0, 0)

    d = np.asarray(distances_m, dtype=float)
    w = np.clip(np.asarray(reputations, dtype=float), 0.05, 1.0)
    theta = 2 * math.pi * d / loop_length_m
    R = loop_length_m / (2 * math.pi)
    X = np.column_stack([R * np.cos(theta), R * np.sin(theta)])

    labels = DBSCAN(eps=eps_m, min_samples=min_weight).fit(X, sample_weight=w).labels_
    clusters = [lbl for lbl in set(labels) if lbl != -1]
    if not clusters:
        return ClusterResult(None, [False] * n, 0.0, 0, n)

    # Cluster ganador = mayor peso total de reputación
    best = max(clusters, key=lambda lbl: w[labels == lbl].sum())
    mask = labels == best
    ang = math.atan2((w[mask] * np.sin(theta[mask])).sum(), (w[mask] * np.cos(theta[mask])).sum())
    center = (ang % (2 * math.pi)) * loop_length_m / (2 * math.pi)

    confidence = float(w[mask].sum() / w.sum()) * min(1.0, mask.sum() / 3)
    return ClusterResult(float(center), mask.tolist(), round(confidence, 3),
                         int(mask.sum()), int(n - mask.sum()))
