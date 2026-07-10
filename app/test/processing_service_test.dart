import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:satellite_app/services/processing_service.dart';

const _polygon =
    '{"type":"Polygon","coordinates":[[[5.66,52.51],[5.7,52.51],[5.7,52.53],[5.66,52.51]]]}';

void main() {
  const config =
      ProcessingConfig(baseUrl: 'https://example.modal.run/', apiKey: 'k1');

  test('fetchScenes posts the right body and parses scenes', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'scenes': [
            {
              'id': 'S2B_TEST',
              'datetime': '2026-06-15T10:30:00Z',
              'cloud_pct': 7.5,
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final scenes = await ProcessingService(config, client: client).fetchScenes(
      polygonGeoJson: _polygon,
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 6, 30),
    );

    // Trailing slash on the base URL must not produce a double slash.
    expect(captured.url.toString(), 'https://example.modal.run/dates');
    expect(captured.headers['x-api-key'], 'k1');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['date_range'], '2026-06-01/2026-06-30');
    expect(body['polygon']['type'], 'Polygon');

    expect(scenes, hasLength(1));
    expect(scenes.first.id, 'S2B_TEST');
    expect(scenes.first.cloudPct, 7.5);
    expect(scenes.first.dateLabel, isNotEmpty);
  });

  test('fetchTruecolor decodes image and bounds', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/process');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['analysis'], 'truecolor');
      expect(body['scene_id'], 'S2B_TEST');
      return http.Response(
        jsonEncode({
          'scene': {
            'id': 'S2B_TEST',
            'datetime': '2026-06-15T10:30:00Z',
            'cloud_pct': 7.5,
          },
          'analysis': 'truecolor',
          'image_b64': base64Encode([1, 2, 3, 4]),
          'bounds': [5.66, 52.51, 5.70, 52.53],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final overlay =
        await ProcessingService(config, client: client).fetchTruecolor(
      polygonGeoJson: _polygon,
      sceneId: 'S2B_TEST',
    );

    expect(overlay.imageBytes, [1, 2, 3, 4]);
    expect(overlay.bounds.southWest.longitude, 5.66);
    expect(overlay.bounds.southWest.latitude, 52.51);
    expect(overlay.bounds.northEast.longitude, 5.70);
    expect(overlay.bounds.northEast.latitude, 52.53);
    expect(overlay.scene.id, 'S2B_TEST');
  });

  test('server error surfaces the detail message', () async {
    final client = MockClient((request) async => http.Response(
          jsonEncode({'detail': 'area is 250.0 km², over the 100 km² limit'}),
          400,
          headers: {'content-type': 'application/json'},
        ));

    expect(
      () => ProcessingService(config, client: client).fetchScenes(
        polygonGeoJson: _polygon,
        start: DateTime(2026, 6, 1),
        end: DateTime(2026, 6, 30),
      ),
      throwsA(isA<ProcessingException>().having(
          (e) => e.message, 'message', contains('over the 100 km² limit'))),
    );
  });
}
