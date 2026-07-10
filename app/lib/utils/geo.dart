import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const double _earthRadiusMeters = 6371008.8;

/// Area of a polygon on a sphere, in square meters.
///
/// Uses the spherical excess approximation (same approach as turf.js /
/// Google's SphericalUtil): accurate to well under a percent for parcels up
/// to hundreds of km², which is far beyond the app's area cap.
double sphericalPolygonAreaSqMeters(List<LatLng> points) {
  if (points.length < 3) return 0;
  double total = 0;
  for (var i = 0; i < points.length; i++) {
    final p1 = points[i];
    final p2 = points[(i + 1) % points.length];
    final lon1 = _degToRad(p1.longitude);
    final lon2 = _degToRad(p2.longitude);
    final lat1 = _degToRad(p1.latitude);
    final lat2 = _degToRad(p2.latitude);
    total += (lon2 - lon1) * (2 + math.sin(lat1) + math.sin(lat2));
  }
  return (total * _earthRadiusMeters * _earthRadiusMeters / 2).abs();
}

double _degToRad(double deg) => deg * math.pi / 180;

/// Human-friendly area string: m² below 1 ha, hectares below 1 km², else km².
String formatArea(double sqMeters) {
  if (sqMeters < 10000) return '${sqMeters.toStringAsFixed(0)} m²';
  if (sqMeters < 1000000) return '${(sqMeters / 10000).toStringAsFixed(2)} ha';
  return '${(sqMeters / 1000000).toStringAsFixed(2)} km²';
}

/// Encodes vertices as a GeoJSON Polygon geometry.
///
/// The ring is closed (first point repeated last) and coordinates are in
/// GeoJSON [longitude, latitude] order — this is the exact geometry the
/// processing service will receive (PLAN.md §5).
String polygonToGeoJson(List<LatLng> points) {
  final ring = [
    for (final p in points) [p.longitude, p.latitude],
    [points.first.longitude, points.first.latitude],
  ];
  return jsonEncode({
    'type': 'Polygon',
    'coordinates': [ring],
  });
}

/// Decodes a GeoJSON Polygon geometry into vertices (without the closing
/// duplicate point). Throws [FormatException] on anything else.
List<LatLng> polygonFromGeoJson(String geoJson) {
  final decoded = jsonDecode(geoJson);
  if (decoded is! Map || decoded['type'] != 'Polygon') {
    throw const FormatException('Expected a GeoJSON Polygon geometry');
  }
  final rings = decoded['coordinates'] as List;
  final ring = (rings.first as List).cast<List>();
  final points = [
    for (final c in ring) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
  ];
  if (points.length > 1 && points.first == points.last) {
    points.removeLast();
  }
  return points;
}

/// Center of a set of vertices — good enough for "zoom to project".
LatLng polygonCenter(List<LatLng> points) {
  var lat = 0.0, lng = 0.0;
  for (final p in points) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / points.length, lng / points.length);
}
