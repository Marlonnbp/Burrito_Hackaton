# app/ — Flutter (Rol A)

Cliente móvil del Burrito Tracker UNMSM. **Solo habla con Supabase** (ver `../CLAUDE.md`).

## 1. Crear el proyecto

```bash
cd app
flutter create --org pe.edu.unmsm --project-name burrito_tracker .
flutter pub add flutter_map latlong2 supabase_flutter geolocator flutter_dotenv
```

Copia `data/route_data.json` como asset (no lo edites aquí; la fuente de verdad es `data/`):

```yaml
# pubspec.yaml
flutter:
  assets:
    - assets/route_data.json
    - .env            # local, gitignored
```

## 2. Inicializar Supabase (anon/publishable key, NUNCA la sb_secret_)

```dart
await dotenv.load();
await Supabase.initialize(
  url: dotenv.env['SUPABASE_URL']!,
  anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
);
```

## 3. Trazar la ruta con flutter_map usando el LineString

```dart
final geo = jsonDecode(await rootBundle.loadString('assets/route_data.json'));
final feats = geo['features'] as List;
final line = feats.firstWhere((f) => f['geometry']['type'] == 'LineString');
final route = (line['geometry']['coordinates'] as List)
    .map((c) => LatLng(c[1], c[0]))      // GeoJSON = [lng, lat]
    .toList()
  ..add(LatLng(line['geometry']['coordinates'][0][1], line['geometry']['coordinates'][0][0])); // cerrar loop

FlutterMap(
  options: const MapOptions(initialCenter: LatLng(-12.0572, -77.0830), initialZoom: 17),
  children: [
    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'pe.edu.unmsm.burrito_tracker'),
    PolylineLayer(polylines: [Polyline(points: route, strokeWidth: 5, color: Colors.amber)]),
    MarkerLayer(markers: [/* paraderos (tabla stops) + bus (bus_state) */]),
  ],
);
```

## 4. Datos en vivo

- **Paraderos**: `supabase.from('stops').select().order('order_index')`
- **Bus**: stream de `bus_state` (id = 1):
  ```dart
  supabase.from('bus_state').stream(primaryKey: ['id']).eq('id', 1)
  ```
  Usa `lat`, `lng`, `status`, `confidence_score` y `etas_json` (lista ordenada por cercanía).
- **Reportar** ("¡El burrito está aquí!"):
  ```dart
  await supabase.from('reports').insert({
    'user_id': userId, 'report_type': 'bus_here',
    'lat': pos.latitude, 'lng': pos.longitude,
    'user_reputation': 0.8, 'is_simulated': false,
  }); // distance_m e is_valid los calcula el backend
  ```
