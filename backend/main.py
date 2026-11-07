"""Burrito Tracker UNMSM — motor de fusión (Rol B).

Loop cada TICK_S segundos:
  reports recientes (Supabase) -> proyección 1D -> DBSCAN anti-trolls
  -> Kalman 1D -> ETAs (RandomForest) -> UPDATE bus_state (id=1)

Solo se comunica con app/ y data/simulator/ vía tablas Supabase.
Ejecutar:  uvicorn main:app --reload --port 8000   (desde backend/)
"""
from __future__ import annotations

import asyncio
import logging
import math
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

from dotenv import load_dotenv
from fastapi import FastAPI, Query
from supabase import Client, create_client

from engine import EtaModel, Kalman1D, filter_reports, get_circuit

load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))
log = logging.getLogger("burrito")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

TICK_S = float(os.getenv("TICK_S", "2"))
WINDOW_S = int(os.getenv("REPORT_WINDOW_S", "90"))
STALE_S = 120
RECENCY_TAU_S = float(os.getenv("RECENCY_TAU_S", "15"))  # peso de un reporte = rep · e^(-edad/τ)

circuit = get_circuit()
kalman = Kalman1D(circuit.length_m)
eta_model = EtaModel(circuit.length_m)
state: dict = {"last_tick": None, "last_fix": None, "stops": circuit.stops, "rejected_total": 0}


def supabase() -> Client:
    return create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"])


def _age_s(created_at: str | None, now: float) -> float:
    """Segundos desde created_at (ISO de Supabase); 0 si no se puede leer."""
    try:
        return max(0.0, now - datetime.fromisoformat(created_at).timestamp())
    except (TypeError, ValueError):
        return 0.0


def aligned_center(rows: list[dict], mask: list[bool], now: float, ref_m: float,
                   max_speed: float = 12.0) -> float | None:
    """Posición ACTUAL estimada a partir de los reportes válidos.

    El promedio simple de una ventana de 90 s queda ~45 s detrás de un bus en
    movimiento. Aquí se ajusta una recta distancia-vs-tiempo (mínimos cuadrados
    ponderados, recientes pesan más) y se evalúa en "ahora". La velocidad sale
    de los propios reportes (no del Kalman) para evitar retroalimentación.
    `ref_m` (centro del cluster) sirve para desenrollar el loop.
    """
    L = circuit.length_m
    pts = []  # (t, d_rel, w), t <= 0 = segundos hacia atrás
    for r, ok in zip(rows, mask):
        if not ok:
            continue
        age = _age_s(r.get("created_at"), now)
        w = (r.get("user_reputation") or 0.5) * math.exp(-age / RECENCY_TAU_S)
        d_rel = (r["distance_m"] - ref_m + L / 2) % L - L / 2
        pts.append((-age, d_rel, w))
    sw = sum(w for _, _, w in pts)
    if sw <= 0:
        return None
    # Evaluar en "ahora", pero sin extrapolar más de 5 s tras el último reporte
    # (si dejan de llegar reportes, el bus no sigue avanzando sin datos).
    t_eval = min(0.0, max(t for t, _, _ in pts) + 5.0)
    t_m = sum(w * t for t, _, w in pts) / sw
    d_m = sum(w * d for _, d, w in pts) / sw
    var_t = sum(w * (t - t_m) ** 2 for t, _, w in pts) / sw
    slope = 0.0
    if len(pts) >= 3 and var_t > 4.0:  # al menos unos segundos de historia
        cov = sum(w * (t - t_m) * (d - d_m) for t, d, w in pts) / sw
        slope = min(max(cov / var_t, 0.0), max_speed)  # el bus solo avanza
    return (ref_m + d_m + slope * (t_eval - t_m)) % L


def tick(sb: Client) -> dict:
    now = time.time()
    dt = now - state["last_tick"] if state["last_tick"] else 0.0
    state["last_tick"] = now
    kalman.predict(dt)

    since = (datetime.now(timezone.utc) - timedelta(seconds=WINDOW_S)).isoformat()
    rows = (sb.table("reports").select("*").gte("created_at", since)
            .order("created_at", desc=True).limit(500).execute().data) or []

    # Proyección 1D (si el cliente no la mandó)
    for r in rows:
        if r.get("distance_m") is None:
            r["distance_m"] = circuit.to_distance(r["lat"], r["lng"])

    res = filter_reports([r["distance_m"] for r in rows],
                         [r.get("user_reputation") or 0.5 for r in rows],
                         circuit.length_m)

    # Marcar validez solo en reportes aún no evaluados
    for r, ok in zip(rows, res.valid_mask):
        if r.get("is_valid") is None:
            sb.table("reports").update({"is_valid": ok, "distance_m": r["distance_m"]}) \
              .eq("uuid", r["uuid"]).execute()
            if not ok:
                state["rejected_total"] += 1

    if res.center_m is not None:
        z = aligned_center(rows, res.valid_mask, now, res.center_m)
        kalman.update(res.center_m if z is None else z,
                      meas_std=max(10.0, 40.0 * (1 - res.confidence)))
        state["last_fix"] = now

    age = now - state["last_fix"] if state["last_fix"] else None
    speed = kalman.speed_mps if kalman.initialized else 0.0
    if age is None:
        status = "unknown"
    elif age > STALE_S:
        status = "stale"
    else:
        status = "moving" if abs(speed) > 0.7 else "stopped"

    pos = kalman.position_m
    lat, lng = circuit.to_latlng(pos)
    confidence = res.confidence if res.center_m is not None else (
        0.0 if age is None else max(0.0, 1 - age / STALE_S) * 0.5)

    bus = {
        "id": 1,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "distance_m": round(pos, 2), "lat": lat, "lng": lng,
        "speed_mps": round(speed, 2),
        "confidence_score": round(confidence, 3),
        "status": status,
        "active_reports_count": res.n_valid,
        "rejected_trolls_count": state["rejected_total"],
        "etas_json": eta_model.predict(pos, speed, state["stops"]) if kalman.initialized else [],
    }
    sb.table("bus_state").upsert(bus).execute()
    return bus


async def engine_loop():
    sb = supabase()
    try:  # usar ids reales de la tabla stops si existen
        db_stops = sb.table("stops").select("*").order("order_index").execute().data
        if db_stops:
            state["stops"] = db_stops
    except Exception as e:  # noqa: BLE001
        log.warning("No se pudo leer stops: %s", e)
    while True:
        try:
            await asyncio.to_thread(tick, sb)
        except Exception as e:  # noqa: BLE001
            log.exception("tick falló: %s", e)
        await asyncio.sleep(TICK_S)


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(engine_loop())
    yield
    task.cancel()


app = FastAPI(title="Burrito Tracker UNMSM — Engine", lifespan=lifespan)


@app.get("/health")
def health():
    return {"ok": True, "loop_length_m": round(circuit.length_m, 2),
            "kalman_initialized": kalman.initialized}


@app.get("/route")
def route():
    return {"loop_length_m": round(circuit.length_m, 2), "stops": circuit.stops}


@app.get("/project")
def project(lat: float = Query(...), lng: float = Query(...)):
    d, off = circuit.project(lat, lng)
    return {"distance_m": round(d, 2), "offset_m": round(off, 2)}
