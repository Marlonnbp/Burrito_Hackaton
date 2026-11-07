"""ETA por paradero con RandomForest.

Features: [distance_ahead_m, speed_mps, n_stops_between, hour].
Arranca entrenado con datos sintéticos (velocidad crucero + dwell por paradero
+ penalización en horas punta); reemplazar por histórico real cuando exista.
"""
from __future__ import annotations

from datetime import datetime

import numpy as np
from sklearn.ensemble import RandomForestRegressor

CRUISE_MPS = 4.5      # ~16 km/h dentro del campus
DWELL_S = 20.0        # parada promedio en paradero


class EtaModel:
    def __init__(self, loop_length_m: float, seed: int = 42):
        self.L = loop_length_m
        self.model = RandomForestRegressor(n_estimators=80, max_depth=10, random_state=seed)
        self._train_synthetic(np.random.default_rng(seed))

    def _train_synthetic(self, rng: np.random.Generator, n: int = 4000) -> None:
        dist = rng.uniform(0, self.L, n)
        speed = rng.uniform(0, 9, n)
        stops = np.floor(dist / (self.L / 9))
        hour = rng.integers(6, 23, n)
        peak = np.isin(hour, [7, 8, 12, 13, 17, 18]).astype(float)
        eff = np.clip(0.6 * CRUISE_MPS + 0.4 * speed, 1.5, None) * (1 - 0.25 * peak)
        y = dist / eff + stops * DWELL_S * (1 + 0.5 * peak) + rng.normal(0, 15, n)
        X = np.column_stack([dist, speed, stops, hour])
        self.model.fit(X, np.clip(y, 0, None))

    def predict(self, bus_m: float, speed_mps: float, stops: list[dict]) -> list[dict]:
        hour = datetime.now().hour
        ahead = [(s, (s["distance_m"] - bus_m) % self.L) for s in stops]
        ahead.sort(key=lambda t: t[1])
        X = np.array([[d, max(speed_mps, 0.0), i, hour] for i, (_, d) in enumerate(ahead)])
        preds = self.model.predict(X) if len(X) else []
        return [
            {"stop_id": s.get("id"), "name": s["name"], "order_index": s.get("order_index"),
             "distance_ahead_m": round(d, 1), "eta_s": int(round(p))}
            for (s, d), p in zip(ahead, preds)
        ]
