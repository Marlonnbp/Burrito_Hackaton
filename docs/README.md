# docs/ — Documentación (Rol C)

## Puesta en marcha

1. **Supabase**: ejecutar en el SQL Editor `data/sql/01_schema.sql` y luego `data/sql/02_seed_stops.sql`.
2. **Secretos**: `cp .env.example .env` y completar `SUPABASE_SERVICE_ROLE_KEY` (pedirla al equipo).
3. **Backend** (Rol B):
   ```bash
   cd backend && python -m venv .venv && .venv/Scripts/activate   # Windows
   pip install -r requirements.txt
   python -m engine.circuit_1d          # verifica loop = 2677.29 m y distance_m de paraderos
   uvicorn main:app --reload --port 8000
   ```
4. **Simulador Modo Dios** (Rol C): `cd data && py -m http.server 5500` → http://localhost:5500/simulator/
5. **App** (Rol A): ver `app/README.md`.

## Flujo de datos

reports (app/simulador) → backend: proyección 1D → DBSCAN anti-trolls (ponderado por reputación,
embebido circular) → Kalman 1D [pos, vel] con innovación circular → ETAs RandomForest → `bus_state` → Realtime → app.
