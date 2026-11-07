"""Filtro de Kalman 1D (posición + velocidad) sobre un loop circular de longitud L."""
from __future__ import annotations

import numpy as np


class Kalman1D:
    def __init__(self, loop_length_m: float, init_m: float = 0.0, init_v: float = 0.0,
                 accel_std: float = 0.5, meas_std: float = 25.0, max_speed: float = 12.0):
        self.L = loop_length_m
        self.x = np.array([init_m, init_v], dtype=float)
        self.P = np.diag([500.0**2, 5.0**2])
        self.q = accel_std**2
        self.r = meas_std**2
        self.max_speed = max_speed
        self.initialized = False

    def predict(self, dt: float) -> None:
        if dt <= 0:
            return
        F = np.array([[1, dt], [0, 1]])
        G = np.array([[0.5 * dt**2], [dt]])
        self.x = F @ self.x
        self.x[0] %= self.L
        self.P = F @ self.P @ F.T + self.q * (G @ G.T)

    def update(self, z_m: float, meas_std: float | None = None) -> None:
        if not self.initialized:
            self.x = np.array([z_m % self.L, 0.0])
            self.P = np.diag([meas_std or 25.0, 3.0]) ** 2
            self.initialized = True
            return
        r = (meas_std**2) if meas_std else self.r
        H = np.array([[1.0, 0.0]])
        y = (z_m - self.x[0] + self.L / 2) % self.L - self.L / 2  # innovación circular
        S = (H @ self.P @ H.T)[0, 0] + r
        K = (self.P @ H.T / S).ravel()
        self.x = self.x + K * y
        self.x[0] %= self.L
        self.x[1] = float(np.clip(self.x[1], -self.max_speed, self.max_speed))
        self.P = (np.eye(2) - np.outer(K, H)) @ self.P

    @property
    def position_m(self) -> float:
        return float(self.x[0])

    @property
    def speed_mps(self) -> float:
        return float(self.x[1])
