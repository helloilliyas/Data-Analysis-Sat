import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class PlaceResult {
  const PlaceResult({required this.displayName, required this.location});

  final String displayName;
  final LatLng location;
}

/// Location search via Nominatim (OpenStreetMap).
///
/// Usage policy: identify the app, max 1 request/second — callers must
/// debounce; this service only searches on explicit submit, never per
/// keystroke.
class GeocodingService {
  GeocodingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _headers = {
    'User-Agent': 'SatelliteLandAnalysis/0.1 (personal prototype)',
  };

  Future<List<PlaceResult>> search(String query) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': query,
      'format': 'jsonv2',
      'limit': '5',
    });
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw http.ClientException(
          'Nominatim returned ${response.statusCode}', uri);
    }
    final results = jsonDecode(response.body) as List;
    return [
      for (final r in results.cast<Map<String, dynamic>>())
        PlaceResult(
          displayName: r['display_name'] as String,
          location: LatLng(
            double.parse(r['lat'] as String),
            double.parse(r['lon'] as String),
          ),
        ),
    ];
  }
}
