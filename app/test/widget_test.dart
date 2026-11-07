import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:app/main.dart';

void main() {
  test('Stop guarda nombre y punto', () {
    const s = Stop('Paradero FISI', LatLng(-12.0536854, -77.0857452));
    expect(s.name, 'Paradero FISI');
  });
}
