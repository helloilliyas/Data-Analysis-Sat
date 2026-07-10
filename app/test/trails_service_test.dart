import 'dart:convert';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:satellite_app/services/trails_service.dart';

void main() {
  final smallBounds = LatLngBounds(
    const LatLng(52.51, 5.66),
    const LatLng(52.53, 5.70),
  );

  test('parses Overpass ways into typed trails', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'overpass-api.de');
      expect(request.bodyFields['data'], contains('path|footway|track'));
      return http.Response(
        jsonEncode({
          'elements': [
            {
              'type': 'way',
              'tags': {'highway': 'track', 'name': 'Field lane'},
              'geometry': [
                {'lat': 52.52, 'lon': 5.67},
                {'lat': 52.521, 'lon': 5.675},
              ],
            },
            {
              'type': 'way',
              'tags': {'highway': 'footway'},
              'geometry': [
                {'lat': 52.515, 'lon': 5.68},
                {'lat': 52.516, 'lon': 5.681},
                {'lat': 52.517, 'lon': 5.682},
              ],
            },
            // Degenerate way: dropped.
            {
              'type': 'way',
              'tags': {'highway': 'path'},
              'geometry': [
                {'lat': 52.51, 'lon': 5.66},
              ],
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final trails =
        await TrailsService(client: client).fetchTrails(smallBounds);
    expect(trails, hasLength(2));
    expect(trails.first.type, 'track');
    expect(trails.first.name, 'Field lane');
    expect(trails.first.points.first.latitude, 52.52);
    expect(trails[1].type, 'footway');
    expect(trails[1].points, hasLength(3));
  });

  test('rejects oversized areas before calling the API', () async {
    final client = MockClient((request) async {
      fail('should not reach the network');
    });
    final hugeBounds = LatLngBounds(
      const LatLng(50.0, 4.0),
      const LatLng(53.0, 7.0),
    );
    expect(
      () => TrailsService(client: client).fetchTrails(hugeBounds),
      throwsA(isA<TrailsException>()),
    );
  });
}
