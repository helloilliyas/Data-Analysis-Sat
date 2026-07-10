import 'dart:convert';

import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// One OSM way rendered as a polyline, classified by its highway tag.
class Trail {
  const Trail({required this.type, required this.points, this.name});

  final String type; // path | footway | track | bridleway | cycleway | steps
  final List<LatLng> points;
  final String? name;
}

class TrailsException implements Exception {
  const TrailsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches paths/tracks/trails from OpenStreetMap via the Overpass API.
///
/// Overpass is a free public service — queries are one-shot on user tap and
/// bounded to a small bbox, keeping usage well within its fair-use policy.
class TrailsService {
  TrailsService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _endpoint = 'https://overpass-api.de/api/interpreter';
  static const _highwayTypes =
      'path|footway|track|bridleway|cycleway|steps';

  /// Refuse queries over huge areas — Overpass would time out or return
  /// megabytes. ~0.3° ≈ 33 km at the equator.
  static const maxSpanDegrees = 0.3;

  Future<List<Trail>> fetchTrails(LatLngBounds bounds) async {
    final latSpan = bounds.north - bounds.south;
    final lngSpan = bounds.east - bounds.west;
    if (latSpan > maxSpanDegrees || lngSpan > maxSpanDegrees) {
      throw const TrailsException(
          'Area too large for trail lookup — zoom in further.');
    }

    final bbox = '${bounds.south},${bounds.west},${bounds.north},${bounds.east}';
    final query = '[out:json][timeout:25];'
        'way["highway"~"^($_highwayTypes)\$"]($bbox);'
        'out geom 400;';

    late http.Response response;
    try {
      response = await _client
          .post(Uri.parse(_endpoint), body: {'data': query})
          .timeout(const Duration(seconds: 40));
    } on Exception catch (e) {
      throw TrailsException('Could not reach OpenStreetMap: $e');
    }
    if (response.statusCode != 200) {
      throw TrailsException(
          'Trail lookup failed (HTTP ${response.statusCode}) — try again shortly.');
    }

    final elements =
        (jsonDecode(response.body)['elements'] as List? ?? const []);
    final trails = <Trail>[];
    for (final element in elements.cast<Map<String, dynamic>>()) {
      final geometry = element['geometry'] as List?;
      if (geometry == null || geometry.length < 2) continue;
      final tags = (element['tags'] as Map?)?.cast<String, dynamic>() ?? {};
      trails.add(Trail(
        type: (tags['highway'] as String?) ?? 'path',
        name: tags['name'] as String?,
        points: [
          for (final p in geometry.cast<Map<String, dynamic>>())
            LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble()),
        ],
      ));
    }
    return trails;
  }
}
