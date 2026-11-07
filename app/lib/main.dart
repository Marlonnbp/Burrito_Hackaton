import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    publishableKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );
  runApp(const BurritoApp());
}

SupabaseClient get supabase => Supabase.instance.client;

const Color kGuinda = Color(0xFF8B1A1A);

/// Fondo del mapa = color de tierra de Voyager, para que no se vean
/// cuadros grises mientras cargan los tiles al hacer zoom.
const Color kFondoMapa = Color(0xFFFAF6F0);

/// Key de CARTO Basemaps (en .env). Sin key se usa OpenStreetMap de respaldo.
String get _cartoKey => (dotenv.env['CARTO_API_KEY'] ?? '').trim();

class BurritoApp extends StatelessWidget {
  const BurritoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Burrito Tracker UNMSM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: kGuinda),
        useMaterial3: true,
      ),
      home: const BurritoMapPage(),
    );
  }
}

/// Paradero leído de route_data.json.
class Stop {
  final String name;
  final LatLng point;
  const Stop(this.name, this.point);
}

/// Extrae (lat, lng) de la fila de bus_state, o null si no hay posición.
LatLng? _busPointOf(Map<String, dynamic>? row) {
  if (row == null || row['lat'] == null || row['lng'] == null) return null;
  return LatLng(
    (row['lat'] as num).toDouble(),
    (row['lng'] as num).toDouble(),
  );
}

class BurritoMapPage extends StatefulWidget {
  const BurritoMapPage({super.key});

  @override
  State<BurritoMapPage> createState() => _BurritoMapPageState();
}

class _BurritoMapPageState extends State<BurritoMapPage> {
  static const LatLng _sanMarcos = LatLng(-12.0560, -77.0845);
  static final LatLngBounds _limites = LatLngBounds(
    const LatLng(-12.0623, -77.0880),
    const LatLng(-12.0521, -77.0783),
  );

  final MapController _mapController = MapController();

  /// Stream creado UNA sola vez (no dentro de build) para no re-suscribirse.
  /// Broadcast: lo escuchan el marcador del bus y el panel inferior por separado.
  late final Stream<List<Map<String, dynamic>>> _busStream = supabase
      .from('bus_state')
      .stream(primaryKey: ['id'])
      .eq('id', 1)
      .asBroadcastStream();

  /// ID anónimo del dispositivo para esta sesión.
  final String _userId =
      'app-${List.generate(12, (_) => Random().nextInt(16).toRadixString(16)).join()}';

  List<LatLng> _route = [];
  List<Marker> _stopMarkers = []; // capa estática, se construye una sola vez
  LatLng? _manualPosition; // fallback: mantener presionado el mapa
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadRoute();
  }

  // ---------------------------------------------------------------------------
  // Ruta (GeoJSON): 1 LineString = pista, Points = paraderos. Coordenadas [lng, lat].
  // ---------------------------------------------------------------------------
  Future<void> _loadRoute() async {
    final raw = await rootBundle.loadString('assets/route_data.json');
    final geo = jsonDecode(raw) as Map<String, dynamic>;
    final route = <LatLng>[];
    final stops = <Stop>[];

    for (final f in geo['features'] as List) {
      final geom = f['geometry'] as Map<String, dynamic>;
      final props = (f['properties'] ?? {}) as Map<String, dynamic>;
      switch (geom['type']) {
        case 'LineString':
          for (final c in geom['coordinates'] as List) {
            route.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
          }
          break;
        case 'Point':
          final c = geom['coordinates'] as List;
          stops.add(Stop(
            (props['name'] ?? 'Paradero') as String,
            LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          ));
          break;
      }
    }

    // El circuito es cerrado: tramo último -> primer vértice.
    if (route.length > 1) route.add(route.first);

    if (!mounted) return;
    setState(() {
      _route = route;
      _stopMarkers = [for (final s in stops) _stopMarker(s)];
    });
  }

  /// Paradero: punto azul con borde blanco, sombra y nombre debajo.
  static Marker _stopMarker(Stop s) => Marker(
        point: s.point,
        width: 20,
        height: 20,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: Colors.blue.shade700,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 23,
              left: -50,
              width: 120,
              child: _StopLabel(s.name.replaceFirst('Paradero ', '')),
            ),
          ],
        ),
      );

  // ---------------------------------------------------------------------------
  // Posición del usuario: GPS, o el punto marcado manualmente (long-press).
  // ---------------------------------------------------------------------------
  Future<LatLng?> _currentPosition() async {
    if (_manualPosition != null) return _manualPosition;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // INSERT en reports. report_type: bus_here | on_board
  // ---------------------------------------------------------------------------
  Future<void> _sendReport(String reportType) async {
    if (_sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final pos = await _currentPosition();
      if (pos == null) {
        messenger.showSnackBar(const SnackBar(
          content: Text(
              'No se pudo obtener tu ubicación. Activa el GPS o mantén presionado el mapa para marcar dónde estás.'),
        ));
        return;
      }

      await supabase.from('reports').insert({
        'user_id': _userId,
        'report_type': reportType,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'is_simulated': false,
        // distance_m, is_valid y user_reputation los resuelve el backend / defaults.
      });

      messenger.showSnackBar(SnackBar(
        content: Text(reportType == 'on_board'
            ? '¡Gracias! Reportaste que vas a bordo 🚌'
            : '¡Gracias! Reportaste que viste pasar el Burrito 👀'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Error al enviar reporte: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Mapa: capas estáticas. Solo el marcador del bus es reactivo.
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _sanMarcos,
              initialZoom: 16,
              minZoom: 15,
              maxZoom: 19,
              backgroundColor: kFondoMapa,
              cameraConstraint: CameraConstraint.containCenter(bounds: _limites),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onLongPress: (_, latLng) {
                setState(() => _manualPosition = latLng);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Ubicación manual marcada 📍'),
                  duration: Duration(seconds: 1),
                ));
              },
            ),
            children: [
              if (_cartoKey.isNotEmpty)
                TileLayer(
                  // CartoDB Voyager (cálido); requiere CARTO_API_KEY.
                  urlTemplate:
                      'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png?key=$_cartoKey',
                  retinaMode: RetinaMode.isHighDensity(context),
                  // La key gratuita solo sirve hasta z18 (z19 = 403); en 19 se escala el 18.
                  maxNativeZoom: 18,
                  maxZoom: 19,
                  keepBuffer: 4, // conserva más tiles al cambiar de zoom
                  userAgentPackageName: 'pe.edu.unmsm.burrito_tracker',
                )
              else
                TileLayer(
                  // Respaldo sin key: OpenStreetMap estándar.
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  maxNativeZoom: 19,
                  maxZoom: 19,
                  userAgentPackageName: 'pe.edu.unmsm.burrito_tracker',
                ),
              if (_route.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _route,
                      strokeWidth: 6.0,
                      color: Colors.orange.shade700,
                    ),
                  ],
                ),
              MarkerLayer(markers: _stopMarkers),
              if (_manualPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _manualPosition!,
                      width: 36,
                      height: 36,
                      child: const Icon(Icons.person_pin_circle,
                          color: Colors.blue, size: 36),
                    ),
                  ],
                ),
              // ÚNICA parte reactiva del mapa: el bus, con movimiento animado.
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _busStream,
                builder: (context, snapshot) {
                  final busPoint = _busPointOf(
                      (snapshot.data?.isNotEmpty ?? false)
                          ? snapshot.data!.first
                          : null);
                  if (busPoint == null) return const SizedBox.shrink();
                  return TweenAnimationBuilder<LatLng>(
                    tween: _LatLngTween(end: busPoint),
                    duration: const Duration(milliseconds: 1200),
                    curve: Curves.easeInOut,
                    builder: (context, point, _) => MarkerLayer(
                      markers: [
                        Marker(
                          point: point,
                          width: 64,
                          height: 40,
                          child: const _BurritoMarker(),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),

          // Atribución del mapa (requisito de licencia)
          Positioned(
            top: MediaQuery.of(context).padding.top + 4,
            left: 4,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                color: Colors.white70,
                child: Text(
                  _cartoKey.isNotEmpty
                      ? '© OpenStreetMap contributors © CARTO'
                      : '© OpenStreetMap contributors',
                  style: const TextStyle(fontSize: 9, color: Colors.black54),
                ),
              ),
            ),
          ),

          // Botón de centrar y panel inferior (fuera del mapa).
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _busStream,
            builder: (context, snapshot) {
              final row = (snapshot.data?.isNotEmpty ?? false)
                  ? snapshot.data!.first
                  : null;
              final busPoint = _busPointOf(row);

              return Stack(
                children: [
                  // Botón para centrar en el Burrito
                  if (busPoint != null)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 12,
                      right: 12,
                      child: FloatingActionButton.small(
                        heroTag: 'center_bus',
                        onPressed: () => _mapController.move(busPoint, 17),
                        child: const Icon(Icons.my_location),
                      ),
                    ),

                  // Panel inferior flotante
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: SafeArea(
                      top: false,
                      child: _BottomPanel(
                        row: row,
                        connected:
                            snapshot.connectionState == ConnectionState.active,
                        hasError: snapshot.hasError,
                        sending: _sending,
                        onSeeIt: () => _sendReport('bus_here'),
                        onBoard: () => _sendReport('on_board'),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Interpola posiciones para que el bus se deslice entre actualizaciones.
class _LatLngTween extends Tween<LatLng> {
  _LatLngTween({super.end});

  @override
  LatLng lerp(double t) => LatLng(
        begin!.latitude + (end!.latitude - begin!.latitude) * t,
        begin!.longitude + (end!.longitude - begin!.longitude) * t,
      );
}

/// Etiqueta del paradero en un rectángulo blanco. Se oculta con zoom < 16
/// para que los nombres no se amontonen al alejar.
class _StopLabel extends StatelessWidget {
  final String text;
  const _StopLabel(this.text);

  @override
  Widget build(BuildContext context) {
    if (MapCamera.of(context).zoom < 16) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: kGuinda.withValues(alpha: 0.35)),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
          ],
        ),
        child: Text(
          text,
          maxLines: 1,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: kGuinda,
          ),
        ),
      ),
    );
  }
}

class _BurritoMarker extends StatelessWidget {
  const _BurritoMarker();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _BusPainter(), size: const Size(64, 40));
}

/// Bus guinda de diseño propio, dibujado en código (sin imágenes externas).
class _BusPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = Paint()..color = kGuinda;
    final dark = Paint()..color = const Color(0xFF2B3A4A);
    final glass = Paint()..color = const Color(0xFFBFE3F5);

    // sombra
    canvas.drawOval(Rect.fromLTWH(w * 0.08, h * 0.88, w * 0.84, h * 0.12),
        Paint()..color = Colors.black26);
    // carrocería
    final bodyR = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, h * 0.08, w, h * 0.72), const Radius.circular(9));
    canvas.drawRRect(bodyR, body);
    canvas.drawRRect(
        bodyR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white);
    // franja
    canvas.drawRect(Rect.fromLTWH(2, h * 0.52, w - 4, h * 0.07), Paint()..color = Colors.white);
    // ventanas
    for (var i = 0; i < 4; i++) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(w * (0.07 + i * 0.185), h * 0.2, w * 0.15, h * 0.22),
              const Radius.circular(3)),
          glass);
    }
    // parabrisas
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.8, h * 0.2, w * 0.15, h * 0.3),
            const Radius.circular(3)),
        dark);
    // ruedas
    for (final x in [0.22, 0.72]) {
      canvas.drawCircle(Offset(w * x, h * 0.8), h * 0.13, dark);
      canvas.drawCircle(Offset(w * x, h * 0.8), h * 0.05, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _BottomPanel extends StatelessWidget {
  final Map<String, dynamic>? row;
  final bool connected;
  final bool hasError;
  final bool sending;
  final VoidCallback onSeeIt;
  final VoidCallback onBoard;

  const _BottomPanel({
    required this.row,
    required this.connected,
    required this.hasError,
    required this.sending,
    required this.onSeeIt,
    required this.onBoard,
  });

  @override
  Widget build(BuildContext context) {
    final String statusText;
    if (hasError) {
      statusText = 'Error de conexión con Supabase';
    } else if (row == null) {
      statusText =
          connected ? 'Esperando posición del Burrito…' : 'Conectando…';
    } else {
      final status = row!['status'] ?? 'unknown';
      final conf = ((row!['confidence_score'] ?? 0) as num) * 100;
      final speed = ((row!['speed_mps'] ?? 0) as num) * 3.6;
      statusText =
          'Estado: $status · Confianza ${conf.toStringAsFixed(0)}% · ${speed.toStringAsFixed(1)} km/h';
    }

    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '🚌 Burrito UNMSM',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(statusText, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    onPressed: sending ? null : onSeeIt,
                    icon: const Icon(Icons.visibility),
                    label: const Text('¡Lo veo pasar!'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      backgroundColor: kGuinda,
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    onPressed: sending ? null : onBoard,
                    icon: sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.directions_bus),
                    label: const Text('Voy a bordo'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
