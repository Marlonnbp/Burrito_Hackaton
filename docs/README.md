# Where is Burrito? 🚌

**Tracker en tiempo real del Burrito, el bus interno de la UNMSM, construido con reportes de los propios estudiantes.**

Sin GPS ni hardware en el bus: cada alumno es un sensor. Los reportes pasan por un filtro de IA que descarta los falsos y estima dónde está el bus y cuánto falta para cada paradero.

> Proyecto de hackathon. Las cifras de precisión se obtuvieron con el simulador sobre la ruta real; el siguiente paso es un piloto en el campus.

---

## El problema

Llegas al paradero y no sabes si el Burrito viene en 1 minuto o en 15. Esperar es una lotería: pierdes tiempo o te vas caminando y el bus pasa justo detrás de ti.

## La solución

1. **Reportas con un toque** que viste el bus o que vas a bordo.
2. **La IA filtra y estima:** agrupa los reportes coincidentes, descarta los aislados (trolls) y calcula la posición actual del bus.
3. **Ves el bus en vivo** en el mapa, con su velocidad, la confianza de la estimación y el ETA a los paraderos.

**Costo de hardware: cero.** Usamos los celulares que los alumnos ya tienen.

---

## Arquitectura

Los tres módulos **no se importan ni se llaman entre sí**: solo se comunican mediante tablas de Supabase y Realtime.

```
app/ (Flutter) ──INSERT reports──►  Supabase  ◄──INSERT reports── data/simulator/ (Modo administrador)
app/ ◄──Realtime bus_state──────    (Postgres)  ──SELECT reports──► backend/ (motor Python)
                                                ◄──UPDATE bus_state── backend/
```

| Módulo | Stack | Responsabilidad |
|---|---|---|
| `app/` | Flutter, flutter_map, supabase_flutter | Reportar, mapa en vivo, estado del bus |
| `backend/` | Python, FastAPI, scikit-learn, NumPy, Shapely | Filtro anti-trolls, estimación de posición, ETAs |
| `data/` | GeoJSON, SQL, HTML + Leaflet | Ruta real, esquema de BD, simulador / panel de administración |
| `docs/` | Markdown | Documentación |

### Pipeline del backend (cada 2 s)

```
reports (últimos 90 s)
  → proyección 1D sobre la ruta (distance_m)
  → DBSCAN circular ponderado por reputación  → marca reports.is_valid
  → posición actual: recta distancia-tiempo de los reportes válidos (recientes pesan más)
  → filtro de Kalman 1D [posición, velocidad] con innovación circular
  → ETAs por paradero (RandomForest)
  → UPDATE bus_state (fila id = 1) → Realtime → app
```

### Circuito 1D

- La única fuente de verdad geométrica es `data/route_data.json`: 9 paraderos (`Point`) y la pista (`LineString`).
- Toda posición se expresa como `distance_m`: metros recorridos sobre la ruta desde su primer vértice, **módulo L = 2677.29 m**. El loop se cierra con el tramo del último al primer vértice.
- Las distancias se calculan con Haversine (R = 6 371 008.8 m).

| # | Paradero | distance_m |
|---|---|---:|
| 1 | Puerta 2 | 168.44 |
| 2 | Puerta 3 | 403.05 |
| 3 | Puerta 7 | 1036.23 |
| 4 | FISI | 1171.91 |
| 5 | Odontología | 1423.09 |
| 6 | Zulen | 1668.37 |
| 7 | Puerta 1 | 2181.39 |
| 8 | Comedor | 2404.34 |
| 9 | FII | 2638.15 |

---

## Estructura del repositorio

```
├── app/                    # Rol A · App Flutter
│   ├── lib/main.dart
│   └── assets/route_data.json
├── backend/                # Rol B · Motor de fusión
│   ├── main.py             # loop: reports → DBSCAN → Kalman → bus_state
│   ├── requirements.txt
│   └── engine/
│       ├── circuit_1d.py   # proyección lat/lng ↔ distance_m
│       ├── dbscan_filter.py
│       ├── kalman_1d.py
│       └── eta_rf.py
├── data/                   # Rol C · Datos y simulador
│   ├── route_data.json     # fuente de verdad geométrica
│   ├── sql/01_schema.sql
│   ├── sql/02_seed_stops.sql
│   └── simulator/index.html
├── docs/
├── .env.example
└── CLAUDE.md               # reglas del proyecto
```

---

## Puesta en marcha

### Requisitos

- Proyecto en [Supabase](https://supabase.com)
- Python 3.11+
- Flutter 3.x (se prueba en Chrome)
- Una API key gratuita de [CARTO Basemaps](https://carto.com/basemaps/apikey) (opcional; sin ella la app usa OpenStreetMap)

### 1. Base de datos

En el **SQL Editor** de Supabase, ejecuta en este orden:

1. `data/sql/01_schema.sql`
2. `data/sql/02_seed_stops.sql`

Esto crea las tablas `stops`, `reports` y `bus_state`, con Realtime activo.

### 2. Variables de entorno

**Backend** (`.env` en la raíz):

```powershell
Copy-Item .env.example .env
```

```env
SUPABASE_URL=https://<tu-proyecto>.supabase.co
SUPABASE_ANON_KEY=<clave pública>
SUPABASE_SERVICE_ROLE_KEY=<clave secreta, pídela al equipo>
```

**App** (`app/.env`):

```env
SUPABASE_URL=https://<tu-proyecto>.supabase.co
SUPABASE_ANON_KEY=<clave pública>
CARTO_API_KEY=<tu key de CARTO>
```

> ⚠️ Nunca subas los archivos `.env` ni claves `sb_secret_*`. La `SUPABASE_SERVICE_ROLE_KEY` solo va en el backend.

### 3. Backend

```powershell
cd backend
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m engine.circuit_1d          # verifica loop = 2677.29 m
uvicorn main:app --reload --port 8000
```

Endpoints de diagnóstico: `GET /health`, `GET /route`, `GET /project?lat=..&lng=..`

### 4. Panel de administración (simulador)

```powershell
cd data
py -m http.server 5500
```

Abre http://localhost:5500/simulator/ y presiona **Conectar**.

### 5. App

```powershell
cd app
flutter pub get
flutter analyze
flutter run -d chrome
```

---

## Cómo hacer la demo

1. Arranca el **backend** y abre el **panel de administración**.
2. En *Simulación de recorrido*, presiona **Iniciar simulación**: un bus virtual recorre la ruta real y usuarios virtuales envían reportes con error de GPS.
3. Presiona **Generar ataques falsos** para inyectar reportes falsos. En el mapa salen en **rojo** (descartados); los válidos salen en **verde**.
4. Abre la **app**: el bus se mueve en vivo y el panel muestra su estado y la confianza.
5. Al terminar, usa **Limpiar reportes simulados**.

| Escenario (simulado) | Error de posición |
|---|---|
| Promedio simple de 90 s (versión inicial) | ~225 m de atraso |
| Versión actual, con 15 % de reportes falsos | ~22 m |

---

## Esquema de base de datos

| Tabla | Campos | Quién escribe |
|---|---|---|
| `stops` | `id`, `name`, `lat`, `lng`, `distance_m`, `order_index` | Seed SQL |
| `reports` | `uuid`, `created_at`, `user_id`, `report_type`, `lat`, `lng`, `distance_m`, `user_reputation`, `is_valid`, `is_simulated` | App y simulador insertan; el backend marca `is_valid` |
| `bus_state` | fila única `id = 1`: `distance_m`, `lat`, `lng`, `speed_mps`, `confidence_score`, `status`, `active_reports_count`, `rejected_trolls_count`, `etas_json` | Solo el backend |

`etas_json`: `[{"stop_id": 1, "name": "...", "distance_ahead_m": 123.4, "eta_s": 57}]`

---

## Equipo

| Integrante | Rol | Carpeta |
|---|---|---|
| **Matías Cerquin** | App: reporte, mapa en vivo y estado del bus | `app/` |
| **Piero Díaz** | IA: filtro anti-trolls y estimación de posición | `backend/` |
| **Marlon Morales** | Datos: ruta real, Supabase y simulador | `data/`, `docs/` |

## Cómo contribuir

- Cada rol hace commits solo en su carpeta. Los cambios a `CLAUDE.md` o a `data/route_data.json` se avisan al equipo.
- Mensajes de commit con [Conventional Commits](https://www.conventionalcommits.org/es/): `feat:`, `fix:`, `docs:`, etc.
- Antes de hacer push: `git pull --rebase`.

## Próximos pasos

- [ ] Piloto real en el campus con reportes de estudiantes
- [ ] Mostrar el ETA al paradero en el panel de la app
- [ ] Entrenar el modelo de ETA con datos históricos reales
