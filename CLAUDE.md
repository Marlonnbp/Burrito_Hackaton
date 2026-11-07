# Burrito Tracker UNMSM — Memoria compartid

Tracker en tiempo real del "Burrito" (bus interno de la UNMSM) basado en reportes
colaborativos (crowdsourcing) de estudiantes, filtrados contra trolls y suavizados
sobre un circuito 1D.

## 1. Desacoplamiento total (regla de oro)

`app/`, `backend/` y `data/simulator/` **NO se importan ni se llaman entre sí**.
Interactúan **SOLO vía tablas Supabase** (`stops`, `reports`, `bus_state`) + Realtime.

```
app/ (Flutter) ──INSERT reports──►  Supabase  ◄──INSERT reports── data/simulator/ (Modo Dios)
app/ ◄──Realtime bus_state──────    (Postgres)  ──SELECT reports──► backend/ (motor Python)
                                                ◄──UPDATE bus_state── backend/
```

- Clientes (app, simulador) **escriben** en `reports` y **leen** `stops` / `bus_state`.
- Solo el backend **escribe** `bus_state` y marca `reports.is_valid`.
- Credenciales en `.env` (gitignored). `.env.example` es la plantilla. La
  `SUPABASE_SERVICE_ROLE_KEY` solo vive en el backend, jamás en app/simulador ni en git.

## 2. Circuito 1D exacto

- La única fuente de verdad geométrica es `data/route_data.json`
  (9 `Point` = paraderos + 1 `LineString` = pista).
- Posición 1D = `distance_m`: metros recorridos sobre la LineString desde su
  **primer vértice** `(-12.0602747, -77.0805066)` en el sentido de los vértices.
- La LineString es abierta (2605.93 m); el circuito se **cierra** con el tramo
  último→primer vértice (71.37 m). **Longitud del loop: `L = 2677.29 m`.**
  Toda `distance_m` vive en `[0, L)` y se opera **módulo L**.
- Distancias calculadas con Haversine (R = 6 371 008.8 m). Cualquier (lat, lng)
  se proyecta al punto más cercano de la pista → `distance_m`
  (`backend/engine/circuit_1d.py`, usa Shapely).

### Paraderos (orden de recorrido)

| order_index | Paradero              | distance_m |
|-------------|-----------------------|-----------:|
| 1           | Paradero Puerta 2     |   168.44 |
| 2           | Paradero Puerta 3     |   403.05 |
| 3           | Paradero Puerta 7     |  1036.23 |
| 4           | Paradero FISI         |  1171.91 |
| 5           | Paradero Odontología  |  1423.09 |
| 6           | Paradero Zulen        |  1668.37 |
| 7           | Paradero Puerta 1     |  2181.39 |
| 8           | Paradero Comedor      |  2404.34 |
| 9           | Paradero FII          |  2638.15 |

(FII cae en el tramo de cierre del loop.)

## 3. Esquema de BD (Supabase / Postgres)

- **`stops`**: `id`, `name`, `lat`, `lng`, `distance_m`, `order_index`
- **`reports`**: `uuid` (PK), `created_at`, `user_id`, `report_type`, `lat`, `lng`,
  `distance_m`, `user_reputation`, `is_valid`, `is_simulated`
- **`bus_state`** (fila única `id = 1`): `id`, `updated_at`, `distance_m`, `lat`, `lng`,
  `speed_mps`, `confidence_score`, `status`, `active_reports_count`,
  `rejected_trolls_count`, `etas_json`

SQL en `data/sql/01_schema.sql` y `data/sql/02_seed_stops.sql` (ejecutar en ese orden
en el SQL Editor de Supabase). RLS deshabilitado (hackathon); Realtime activo en las 3 tablas.

`etas_json` formato: `[{"stop_id":1,"name":"...","distance_ahead_m":123.4,"eta_s":57}]`.

## 4. Regla Git (propiedad de carpetas)

| Rol | Stack | Carpeta |
|-----|-------|---------|
| A | Flutter + flutter_map | `app/` |
| B | Python (FastAPI, DBSCAN, Kalman, RF) | `backend/` |
| C | Datos / GIS / Simulador / Docs | `data/` y `docs/` |

- Cada rol solo hace commit en su carpeta. Cambios a `CLAUDE.md` o a
  `data/route_data.json` se avisan al equipo.
- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`...). `git pull --rebase` antes de push.
- Nunca commitear `.env` ni claves `sb_secret_*`.
