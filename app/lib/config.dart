/// Build-time configuration.
///
/// Provide a MapTiler key for production-quality basemap tiles:
///   flutter run --dart-define=MAPTILER_KEY=yourkey
/// Without a key the app falls back to the public OpenStreetMap tile server,
/// which is acceptable for personal development use only (see OSM tile usage
/// policy) — get a free MapTiler/Stadia key before wider use.
class MapConfig {
  static const maptilerKey = String.fromEnvironment('MAPTILER_KEY');

  static bool get hasMaptilerKey => maptilerKey.isNotEmpty;

  static String get tileUrl => hasMaptilerKey
      ? 'https://api.maptiler.com/maps/streets-v2/256/{z}/{x}/{y}.png?key=$maptilerKey'
      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  static String get attribution => hasMaptilerKey
      ? '© MapTiler  © OpenStreetMap contributors'
      : '© OpenStreetMap contributors';

  /// Sent with tile requests so the provider can identify the app.
  static const userAgentPackageName = 'com.illiyas.satellite_app';
}

/// Maximum drawable area. Keeps processing requests small and cheap
/// (PLAN.md §2) — enforced at save time and shown in the area readout.
const double kMaxAreaSqKm = 100.0;
