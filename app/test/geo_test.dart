import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:satellite_app/utils/geo.dart';

void main() {
  group('sphericalPolygonAreaSqMeters', () {
    test('returns 0 for fewer than 3 points', () {
      expect(sphericalPolygonAreaSqMeters([]), 0);
      expect(
        sphericalPolygonAreaSqMeters(
            [const LatLng(0, 0), const LatLng(0, 0.01)]),
        0,
      );
    });

    test('~1 km square near the equator is ~1 km²', () {
      // 0.009 degrees of latitude ≈ 1 km; same for longitude at the equator.
      const d = 0.009;
      final area = sphericalPolygonAreaSqMeters([
        const LatLng(0, 0),
        const LatLng(0, d),
        const LatLng(d, d),
        const LatLng(d, 0),
      ]);
      expect(area, closeTo(1000000, 15000)); // within 1.5 %
    });

    test('winding order does not change magnitude', () {
      final cw = [
        const LatLng(10, 10),
        const LatLng(10, 10.01),
        const LatLng(10.01, 10.01),
      ];
      final ccw = cw.reversed.toList();
      expect(sphericalPolygonAreaSqMeters(cw),
          closeTo(sphericalPolygonAreaSqMeters(ccw), 0.001));
    });
  });

  group('formatArea', () {
    test('picks sensible units', () {
      expect(formatArea(500), '500 m²');
      expect(formatArea(25000), '2.50 ha');
      expect(formatArea(3500000), '3.50 km²');
    });
  });

  group('GeoJSON round trip', () {
    test('encodes a closed ring in [lng, lat] order and decodes back', () {
      final points = [
        const LatLng(51.5, -0.1),
        const LatLng(51.5, -0.09),
        const LatLng(51.51, -0.09),
      ];
      final geoJson = polygonToGeoJson(points);
      expect(geoJson, contains('"type":"Polygon"'));
      // First coordinate must be [lng, lat].
      expect(geoJson, contains('[-0.1,51.5]'));

      final decoded = polygonFromGeoJson(geoJson);
      expect(decoded, points); // closing duplicate removed
    });

    test('rejects non-polygon geometry', () {
      expect(
        () => polygonFromGeoJson('{"type":"Point","coordinates":[0,0]}'),
        throwsFormatException,
      );
    });
  });

  test('polygonCenter averages vertices', () {
    final center = polygonCenter([
      const LatLng(0, 0),
      const LatLng(0, 2),
      const LatLng(2, 2),
      const LatLng(2, 0),
    ]);
    expect(center.latitude, 1);
    expect(center.longitude, 1);
  });
}
