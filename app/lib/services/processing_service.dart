import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Connection details for the FastAPI/Modal processing service, entered by
/// the user in Settings and stored in the local database.
class ProcessingConfig {
  const ProcessingConfig({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  bool get isConfigured => baseUrl.isNotEmpty;
}

class SceneInfo {
  const SceneInfo({
    required this.id,
    required this.dateTime,
    required this.cloudPct,
  });

  factory SceneInfo.fromJson(Map<String, dynamic> json) => SceneInfo(
        id: json['id'] as String,
        dateTime: DateTime.parse(json['datetime'] as String),
        cloudPct: (json['cloud_pct'] as num).toDouble(),
      );

  final String id;
  final DateTime dateTime;
  final double cloudPct;

  String get dateLabel {
    final d = dateTime.toLocal();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}

/// Summary statistics returned with NDVI / ΔNDVI results.
class SceneStats {
  const SceneStats({
    required this.mean,
    required this.min,
    required this.max,
    required this.validPixelPct,
    required this.aoiCloudPct,
  });

  factory SceneStats.fromJson(Map<String, dynamic> json) => SceneStats(
        mean: (json['mean'] as num?)?.toDouble(),
        min: (json['min'] as num?)?.toDouble(),
        max: (json['max'] as num?)?.toDouble(),
        validPixelPct: (json['valid_pixel_pct'] as num?)?.toDouble() ?? 0,
        aoiCloudPct: (json['aoi_cloud_pct'] as num?)?.toDouble() ?? 0,
      );

  final double? mean;
  final double? min;
  final double? max;
  final double validPixelPct;
  final double aoiCloudPct;
}

/// A processed image ready to overlay on the map.
class ImageryOverlay {
  const ImageryOverlay({
    required this.imageBytes,
    required this.bounds,
    required this.scene,
    required this.analysis,
    this.sceneB,
    this.stats,
  });

  final Uint8List imageBytes;
  final LatLngBounds bounds;
  final SceneInfo scene;
  final String analysis;
  final SceneInfo? sceneB;

  /// For ndvi: that date's stats. For ndvi_compare: ΔNDVI stats.
  final SceneStats? stats;
}

class ProcessingException implements Exception {
  const ProcessingException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ProcessingService {
  ProcessingService(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  final ProcessingConfig config;
  final http.Client _client;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (config.apiKey.isNotEmpty) 'x-api-key': config.apiKey,
      };

  Uri _endpoint(String path) {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    return Uri.parse('$base$path');
  }

  static String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    late http.Response response;
    try {
      response = await _client
          .post(_endpoint(path), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 120));
    } on Exception catch (e) {
      throw ProcessingException('Could not reach the processing server: $e');
    }
    final decoded = jsonDecode(response.body);
    if (response.statusCode != 200) {
      final detail =
          decoded is Map && decoded['detail'] != null ? decoded['detail'] : '';
      throw ProcessingException(
          'Server error ${response.statusCode}${detail != '' ? ': $detail' : ''}');
    }
    return decoded as Map<String, dynamic>;
  }

  /// Available Sentinel-2 scenes for the area, newest first. Cloud cover is
  /// scene-level — a rough guide for picking a date.
  Future<List<SceneInfo>> fetchScenes({
    required String polygonGeoJson,
    required DateTime start,
    required DateTime end,
    double maxCloud = 100,
  }) async {
    final body = await _post('/dates', {
      'polygon': jsonDecode(polygonGeoJson),
      'date_range': '${_formatDate(start)}/${_formatDate(end)}',
      'max_cloud': maxCloud,
    });
    return [
      for (final s in (body['scenes'] as List).cast<Map<String, dynamic>>())
        SceneInfo.fromJson(s),
    ];
  }

  /// Runs an analysis for one scene (or two for ndvi_compare), cropped to
  /// the area. [analysis] is 'truecolor', 'ndvi' or 'ndvi_compare'; for the
  /// latter [sceneIdB] is the later date and the image shows ΔNDVI = B − A.
  Future<ImageryOverlay> fetchAnalysis({
    required String polygonGeoJson,
    required String sceneId,
    required String analysis,
    String? sceneIdB,
  }) async {
    final body = await _post('/process', {
      'polygon': jsonDecode(polygonGeoJson),
      'analysis': analysis,
      'scene_id': sceneId,
      if (sceneIdB != null) 'scene_id_b': sceneIdB,
    });
    final bounds = (body['bounds'] as List).cast<num>();
    return ImageryOverlay(
      imageBytes: base64Decode(body['image_b64'] as String),
      bounds: LatLngBounds(
        LatLng(bounds[1].toDouble(), bounds[0].toDouble()),
        LatLng(bounds[3].toDouble(), bounds[2].toDouble()),
      ),
      scene: SceneInfo.fromJson(body['scene'] as Map<String, dynamic>),
      analysis: body['analysis'] as String,
      sceneB: body['scene_b'] == null
          ? null
          : SceneInfo.fromJson(body['scene_b'] as Map<String, dynamic>),
      stats: body['stats'] == null
          ? null
          : SceneStats.fromJson(body['stats'] as Map<String, dynamic>),
    );
  }
}
