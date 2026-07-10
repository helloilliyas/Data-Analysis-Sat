import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class LocationException implements Exception {
  const LocationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Wraps geolocator's service/permission dance into one call.
Future<LatLng> getCurrentLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationException(
        'Location services are turned off on this device.');
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw const LocationException(
        'Location permission denied. Enable it in app settings.');
  }

  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
  );
  return LatLng(position.latitude, position.longitude);
}
