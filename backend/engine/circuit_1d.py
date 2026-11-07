"""Circuito 1D exacto: mapea cualquier (lat, lng) a distance_m sobre la pista.

Fuente de verdad: data/route_data.json (LineString + 9 paraderos).
- Origen (distance_m = 0) = primer vértice de la LineString.
- El loop se cierra con el tramo último -> primer vértice (L ~= 2677.29 m).
- Shapely hace el snap geométrico (en un plano local métrico) y la
  distancia a lo largo se mide con Haversine, igual que data/sql/02_seed_stops.sql.
"""
from __future__ import annotations

import json
import math
from functools import lru_cache
from pathlib import Path

from shapely.geometry import LineString, Point

EARTH_R = 6_371_008.8
ROUTE_PATH = Path(__file__).resolve().parents[2] / "data" / "route_data.json"


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(h))


class Circuit1D:
    def __init__(self, route_path: Path = ROUTE_PATH):
        geo = json.loads(Path(route_path).read_text(encoding="utf-8"))
        line = next(f for f in geo["features"] if f["geometry"]["type"] == "LineString")
        coords = [tuple(c) for c in line["geometry"]["coordinates"]]  # (lng, lat)
        if coords[0] != coords[-1]:
            coords.append(coords[0])  # cerrar el loop
        self.coords = coords

        # Plano local equirectangular (solo para el snap; las distancias son Haversine)
        self._lat0 = sum(c[1] for c in coords) / len(coords)
        self._kx = math.cos(math.radians(self._lat0))
        self._line_xy = LineString([self._to_xy(lat, lng) for lng, lat in coords])

        # Distancia acumulada Haversine por vértice
        self.cum = [0.0]
        for (lng1, lat1), (lng2, lat2) in zip(coords, coords[1:]):
            self.cum.append(self.cum[-1] + haversine_m(lat1, lng1, lat2, lng2))
        self.length_m = self.cum[-1]

        self.stops = [
            {"name": f["properties"]["name"],
             "lat": f["geometry"]["coordinates"][1],
             "lng": f["geometry"]["coordinates"][0]}
            for f in geo["features"] if f["geometry"]["type"] == "Point"
        ]
        for s in self.stops:
            s["distance_m"] = round(self.project(s["lat"], s["lng"])[0], 2)
        self.stops.sort(key=lambda s: s["distance_m"])
        for i, s in enumerate(self.stops, 1):
            s["order_index"] = i

    # --- helpers de proyección ---
    def _to_xy(self, lat: float, lng: float) -> tuple[float, float]:
        return (math.radians(lng) * self._kx * EARTH_R, math.radians(lat) * EARTH_R)

    def _from_xy(self, x: float, y: float) -> tuple[float, float]:
        return (math.degrees(y / EARTH_R), math.degrees(x / (self._kx * EARTH_R)))

    # --- API pública ---
    def project(self, lat: float, lng: float) -> tuple[float, float]:
        """(lat, lng) -> (distance_m sobre el loop, offset_m perpendicular a la pista)."""
        p = Point(self._to_xy(lat, lng))
        snapped = self._line_xy.interpolate(self._line_xy.project(p))
        s_lat, s_lng = self._from_xy(snapped.x, snapped.y)

        # localizar el segmento que contiene el punto proyectado
        xy = list(self._line_xy.coords)
        best_i, best_d = 0, float("inf")
        for i in range(len(xy) - 1):
            d = LineString([xy[i], xy[i + 1]]).distance(snapped)
            if d < best_d:
                best_i, best_d = i, d
        v_lng, v_lat = self.coords[best_i]
        dist = self.cum[best_i] + haversine_m(v_lat, v_lng, s_lat, s_lng)
        return dist % self.length_m, haversine_m(lat, lng, s_lat, s_lng)

    def to_distance(self, lat: float, lng: float) -> float:
        return self.project(lat, lng)[0]

    def to_latlng(self, distance_m: float) -> tuple[float, float]:
        """distance_m -> (lat, lng) sobre la pista."""
        d = distance_m % self.length_m
        for i in range(len(self.cum) - 1):
            if self.cum[i] <= d <= self.cum[i + 1]:
                seg = self.cum[i + 1] - self.cum[i]
                t = 0.0 if seg == 0 else (d - self.cum[i]) / seg
                (lng1, lat1), (lng2, lat2) = self.coords[i], self.coords[i + 1]
                return lat1 + t * (lat2 - lat1), lng1 + t * (lng2 - lng1)
        lng, lat = self.coords[0]
        return lat, lng

    def ahead(self, from_m: float, to_m: float) -> float:
        """Metros a recorrer (en sentido de marcha) de from_m a to_m."""
        return (to_m - from_m) % self.length_m

    def wrap_delta(self, a: float, b: float) -> float:
        """Diferencia firmada b - a en [-L/2, L/2)."""
        L = self.length_m
        return (b - a + L / 2) % L - L / 2


@lru_cache(maxsize=1)
def get_circuit() -> Circuit1D:
    return Circuit1D()


if __name__ == "__main__":
    c = get_circuit()
    print(f"Loop length: {c.length_m:.2f} m")
    for s in c.stops:
        print(s["order_index"], s["name"], s["distance_m"])
