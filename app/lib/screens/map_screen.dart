import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../db/database.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart';
import '../services/processing_service.dart';
import '../services/trails_service.dart';
import '../utils/geo.dart';
import '../widgets/server_settings_dialog.dart';

enum _EditMode { add, move, delete }

/// Map screen: draw/edit the land area polygon, locate via GPS, search
/// places, and save the area as a project.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.db, this.project});

  final AppDatabase db;

  /// When set, the screen opens editing this existing project.
  final Project? project;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _mapController = MapController();
  final _geocoding = GeocodingService();

  List<LatLng> _vertices = [];
  final List<List<LatLng>> _history = [];
  _EditMode _mode = _EditMode.add;
  int? _selectedVertex;
  bool _locating = false;
  ImageryOverlay? _overlay;
  double _overlayOpacity = 1;
  bool _loadingImagery = false;
  List<Trail>? _trails;
  bool _loadingTrails = false;

  static const _initialCenter = LatLng(20.0, 0.0);
  static const _initialZoom = 2.5;

  double get _areaSqMeters => sphericalPolygonAreaSqMeters(_vertices);
  bool get _overCap => _areaSqMeters > kMaxAreaSqKm * 1000000;

  @override
  void initState() {
    super.initState();
    final project = widget.project;
    if (project != null) {
      _vertices = polygonFromGeoJson(project.areaGeoJson);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(polygonCenter(_vertices), 14);
      });
    }
  }

  void _pushHistory() => _history.add(List.of(_vertices));

  void _undo() {
    if (_history.isEmpty) return;
    setState(() {
      _vertices = _history.removeLast();
      _selectedVertex = null;
    });
  }

  void _clear() {
    if (_vertices.isEmpty) return;
    setState(() {
      _pushHistory();
      _vertices = [];
      _selectedVertex = null;
    });
  }

  void _onMapTap(TapPosition tapPosition, LatLng latLng) {
    setState(() {
      switch (_mode) {
        case _EditMode.add:
          _pushHistory();
          _vertices.add(latLng);
        case _EditMode.move:
          final selected = _selectedVertex;
          if (selected != null) {
            _pushHistory();
            _vertices[selected] = latLng;
            _selectedVertex = null;
          }
        case _EditMode.delete:
          break;
      }
    });
  }

  void _onVertexTap(int index) {
    setState(() {
      switch (_mode) {
        case _EditMode.add:
          break;
        case _EditMode.move:
          _selectedVertex = _selectedVertex == index ? null : index;
        case _EditMode.delete:
          _pushHistory();
          _vertices.removeAt(index);
          _selectedVertex = null;
      }
    });
  }

  Future<void> _goToCurrentLocation() async {
    setState(() => _locating = true);
    try {
      final here = await getCurrentLocation();
      _mapController.move(here, 16);
    } on LocationException catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('Could not get location: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _openImagery() async {
    if (_vertices.length < 3) {
      _showMessage('Draw an area first (at least 3 points).');
      return;
    }
    var config = await loadProcessingConfig(widget.db);
    if (!config.isConfigured) {
      if (!mounted) return;
      config = await showServerSettingsDialog(context, widget.db) ??
          const ProcessingConfig(baseUrl: '', apiKey: '');
      if (!config.isConfigured) return;
    }
    if (!mounted) return;

    final service = ProcessingService(config);
    final polygonGeoJson = polygonToGeoJson(_vertices);
    final choice = await showModalBottomSheet<_ImageryChoice>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _ImagerySheet(service: service, polygonGeoJson: polygonGeoJson),
    );
    if (choice == null || !mounted) return;

    setState(() => _loadingImagery = true);
    try {
      final overlay = await service.fetchAnalysis(
        polygonGeoJson: polygonGeoJson,
        sceneId: choice.sceneA.id,
        analysis: choice.analysis,
        sceneIdB: choice.sceneB?.id,
      );
      if (!mounted) return;
      setState(() => _overlay = overlay);
    } on ProcessingException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _loadingImagery = false);
    }
  }

  Future<void> _toggleTrails() async {
    if (_trails != null) {
      setState(() => _trails = null);
      return;
    }
    // Prefer the drawn area; fall back to the visible map region.
    final bounds = _vertices.length >= 3
        ? LatLngBounds.fromPoints(_vertices)
        : _mapController.camera.visibleBounds;

    setState(() => _loadingTrails = true);
    try {
      final trails = await TrailsService().fetchTrails(bounds);
      if (!mounted) return;
      setState(() => _trails = trails);
      _showMessage(trails.isEmpty
          ? 'No mapped paths or tracks here (per OpenStreetMap).'
          : '${trails.length} paths/tracks found.');
    } on TrailsException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _loadingTrails = false);
    }
  }

  static Color _trailColor(String type) => switch (type) {
        'track' => Colors.brown,
        'cycleway' => Colors.blue,
        'bridleway' => Colors.deepPurple,
        'steps' => Colors.redAccent,
        _ => const Color(0xFF1B5E20), // path, footway
      };

  Future<void> _openSearch() async {
    final result = await showDialog<PlaceResult>(
      context: context,
      builder: (context) => _SearchDialog(geocoding: _geocoding),
    );
    if (result != null) {
      _mapController.move(result.location, 14);
    }
  }

  Future<void> _save() async {
    if (_vertices.length < 3) {
      _showMessage('Draw at least 3 points to define an area.');
      return;
    }
    if (_overCap) {
      _showMessage(
          'Area exceeds the ${kMaxAreaSqKm.toStringAsFixed(0)} km² limit — '
          'draw a smaller area.');
      return;
    }

    final existing = widget.project;
    if (existing != null) {
      await widget.db.updateProjectArea(
        id: existing.id,
        areaGeoJson: polygonToGeoJson(_vertices),
        areaSqMeters: _areaSqMeters,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }

    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;

    await widget.db.insertProject(
      name: name.trim(),
      areaGeoJson: polygonToGeoJson(_vertices),
      areaSqMeters: _areaSqMeters,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project?.name ?? 'New area'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search location',
            onPressed: _openSearch,
          ),
          IconButton(
            icon: _loadingImagery
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.satellite_alt),
            tooltip: 'Satellite imagery',
            onPressed: _loadingImagery ? null : _openImagery,
          ),
          IconButton(
            icon: _loadingTrails
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_trails == null ? Icons.route : Icons.route_outlined),
            tooltip:
                _trails == null ? 'Show paths & trails' : 'Hide paths & trails',
            onPressed: _loadingTrails ? null : _toggleTrails,
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.project != null
                  ? polygonCenter(_vertices)
                  : _initialCenter,
              initialZoom: widget.project != null ? 14 : _initialZoom,
              onTap: _onMapTap,
            ),
            children: [
              TileLayer(
                urlTemplate: MapConfig.tileUrl,
                userAgentPackageName: MapConfig.userAgentPackageName,
              ),
              if (_overlay != null)
                Opacity(
                  opacity: _overlayOpacity,
                  child: OverlayImageLayer(overlayImages: [
                    OverlayImage(
                      bounds: _overlay!.bounds,
                      imageProvider: MemoryImage(_overlay!.imageBytes),
                    ),
                  ]),
                ),
              if (_vertices.length >= 3)
                PolygonLayer(polygons: [
                  Polygon(
                    points: _vertices,
                    color: (_overCap ? Colors.red : Colors.green)
                        .withValues(alpha: 0.25),
                    borderColor: _overCap ? Colors.red : Colors.green,
                    borderStrokeWidth: 2,
                  ),
                ]),
              if (_vertices.length == 2)
                PolylineLayer(polylines: [
                  Polyline(
                      points: _vertices,
                      color: Colors.green,
                      strokeWidth: 2),
                ]),
              if (_trails != null && _trails!.isNotEmpty)
                PolylineLayer(polylines: [
                  for (final trail in _trails!)
                    Polyline(
                      points: trail.points,
                      color: _trailColor(trail.type),
                      strokeWidth: 3,
                    ),
                ]),
              MarkerLayer(markers: [
                for (var i = 0; i < _vertices.length; i++)
                  Marker(
                    point: _vertices[i],
                    width: 28,
                    height: 28,
                    child: GestureDetector(
                      onTap: () => _onVertexTap(i),
                      child: _VertexDot(
                        index: i,
                        selected: _selectedVertex == i,
                        deleteMode: _mode == _EditMode.delete,
                      ),
                    ),
                  ),
              ]),
              const SimpleAttributionWidget(
                source: Text('OpenStreetMap contributors'),
              ),
            ],
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_overlay != null)
                  _OverlayControlCard(
                    overlay: _overlay!,
                    opacity: _overlayOpacity,
                    onOpacityChanged: (v) =>
                        setState(() => _overlayOpacity = v),
                    onClose: () => setState(() => _overlay = null),
                  ),
                _EditPanel(
                  mode: _mode,
                  onModeChanged: (m) => setState(() {
                    _mode = m;
                    _selectedVertex = null;
                  }),
                  areaLabel: _vertices.length >= 3
                      ? '${formatArea(_areaSqMeters)}${_overCap ? '  (over ${kMaxAreaSqKm.toStringAsFixed(0)} km² limit)' : ''}'
                      : 'Tap the map to add points',
                  overCap: _overCap,
                  canUndo: _history.isNotEmpty,
                  hasVertices: _vertices.isNotEmpty,
                  moveHint: _mode == _EditMode.move && _selectedVertex != null,
                  onUndo: _undo,
                  onClear: _clear,
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'locate',
            tooltip: 'My location',
            onPressed: _locating ? null : _goToCurrentLocation,
            child: _locating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.extended(
            heroTag: 'save',
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Save'),
          ),
          // Leave room for the edit panel below the FABs.
          const SizedBox(height: 96),
        ],
      ),
    );
  }
}

class _VertexDot extends StatelessWidget {
  const _VertexDot({
    required this.index,
    required this.selected,
    required this.deleteMode,
  });

  final int index;
  final bool selected;
  final bool deleteMode;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Colors.orange
        : deleteMode
            ? Colors.red
            : Colors.green;
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        '${index + 1}',
        style: const TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _EditPanel extends StatelessWidget {
  const _EditPanel({
    required this.mode,
    required this.onModeChanged,
    required this.areaLabel,
    required this.overCap,
    required this.canUndo,
    required this.hasVertices,
    required this.moveHint,
    required this.onUndo,
    required this.onClear,
  });

  final _EditMode mode;
  final ValueChanged<_EditMode> onModeChanged;
  final String areaLabel;
  final bool overCap;
  final bool canUndo;
  final bool hasVertices;
  final bool moveHint;
  final VoidCallback onUndo;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    moveHint ? 'Tap the map to place the point' : areaLabel,
                    style: TextStyle(
                      color: overCap ? Colors.red : null,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: 'Undo',
                  onPressed: canUndo ? onUndo : null,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  tooltip: 'Clear area',
                  onPressed: hasVertices ? onClear : null,
                ),
              ],
            ),
            SegmentedButton<_EditMode>(
              segments: const [
                ButtonSegment(
                    value: _EditMode.add,
                    icon: Icon(Icons.add_location_alt),
                    label: Text('Add')),
                ButtonSegment(
                    value: _EditMode.move,
                    icon: Icon(Icons.open_with),
                    label: Text('Move')),
                ButtonSegment(
                    value: _EditMode.delete,
                    icon: Icon(Icons.wrong_location),
                    label: Text('Delete')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => onModeChanged(s.first),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverlayControlCard extends StatelessWidget {
  const _OverlayControlCard({
    required this.overlay,
    required this.opacity,
    required this.onOpacityChanged,
    required this.onClose,
  });

  final ImageryOverlay overlay;
  final double opacity;
  final ValueChanged<double> onOpacityChanged;
  final VoidCallback onClose;

  String get _label {
    final stats = overlay.stats;
    switch (overlay.analysis) {
      case 'ndvi':
        final mean = stats?.mean;
        return 'NDVI ${overlay.scene.dateLabel}'
            '${mean != null ? ' · mean ${mean.toStringAsFixed(2)}' : ''}'
            '${stats != null ? ' · ${stats.aoiCloudPct.toStringAsFixed(0)}% cloud' : ''}';
      case 'ndvi_compare':
        final mean = stats?.mean;
        final sign = (mean ?? 0) >= 0 ? '+' : '';
        return 'ΔNDVI ${overlay.scene.dateLabel} → '
            '${overlay.sceneB?.dateLabel ?? '?'}'
            '${mean != null ? ' · $sign${mean.toStringAsFixed(2)}' : ''}';
      default:
        return '${overlay.scene.dateLabel} · '
            '${overlay.scene.cloudPct.toStringAsFixed(0)}% cloud';
    }
  }

  IconData get _icon => switch (overlay.analysis) {
        'ndvi' => Icons.grass,
        'ndvi_compare' => Icons.compare,
        _ => Icons.satellite_alt,
      };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(_icon, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _label,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 110,
              child: Slider(
                value: opacity,
                onChanged: onOpacityChanged,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Remove imagery',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// What the user picked in the imagery sheet.
class _ImageryChoice {
  const _ImageryChoice({
    required this.analysis,
    required this.sceneA,
    this.sceneB,
  });

  final String analysis; // truecolor | ndvi | ndvi_compare
  final SceneInfo sceneA;
  final SceneInfo? sceneB;
}

/// Bottom sheet listing available Sentinel-2 scenes for the drawn area.
/// Pops with an [_ImageryChoice].
class _ImagerySheet extends StatefulWidget {
  const _ImagerySheet({required this.service, required this.polygonGeoJson});

  final ProcessingService service;
  final String polygonGeoJson;

  @override
  State<_ImagerySheet> createState() => _ImagerySheetState();
}

class _ImagerySheetState extends State<_ImagerySheet> {
  late DateTimeRange _range;
  List<SceneInfo>? _scenes;
  String? _error;
  String _analysis = 'truecolor';
  SceneInfo? _compareFirst;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(start: now.subtract(const Duration(days: 90)), end: now);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _scenes = null;
      _error = null;
    });
    try {
      final scenes = await widget.service.fetchScenes(
        polygonGeoJson: widget.polygonGeoJson,
        start: _range.start,
        end: _range.end,
      );
      if (!mounted) return;
      setState(() => _scenes = scenes);
    } on ProcessingException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2017), // Sentinel-2 L2A archive start
      lastDate: DateTime.now(),
      initialDateRange: _range,
    );
    if (picked != null) {
      setState(() => _range = picked);
      await _load();
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  void _onSceneTap(SceneInfo scene) {
    if (_analysis != 'ndvi_compare') {
      Navigator.of(context)
          .pop(_ImageryChoice(analysis: _analysis, sceneA: scene));
      return;
    }
    final first = _compareFirst;
    if (first == null || first.id == scene.id) {
      setState(() => _compareFirst = first == null ? scene : null);
      return;
    }
    // Server computes Δ = B − A, so order by date: A earlier, B later.
    final aFirst = first.dateTime.isBefore(scene.dateTime);
    Navigator.of(context).pop(_ImageryChoice(
      analysis: 'ndvi_compare',
      sceneA: aFirst ? first : scene,
      sceneB: aFirst ? scene : first,
    ));
  }

  String get _hint => switch (_analysis) {
        'ndvi_compare' => _compareFirst == null
            ? 'Pick the first of two dates to compare.'
            : 'Now pick the second date.',
        'ndvi' =>
          'Vegetation index — clouds are masked out automatically.',
        _ => 'Cloud % is for the whole scene — your area may differ.',
      };

  @override
  Widget build(BuildContext context) {
    final scenes = _scenes;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Satellite imagery',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.date_range, size: 18),
                  label: Text('${_fmt(_range.start)} → ${_fmt(_range.end)}'),
                  onPressed: _pickRange,
                ),
              ],
            ),
            Center(
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'truecolor',
                      icon: Icon(Icons.photo),
                      label: Text('Photo')),
                  ButtonSegment(
                      value: 'ndvi',
                      icon: Icon(Icons.grass),
                      label: Text('NDVI')),
                  ButtonSegment(
                      value: 'ndvi_compare',
                      icon: Icon(Icons.compare),
                      label: Text('Compare')),
                ],
                selected: {_analysis},
                onSelectionChanged: (s) => setState(() {
                  _analysis = s.first;
                  _compareFirst = null;
                }),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _hint,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              )
            else if (scenes == null)
              const Center(
                  child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ))
            else if (scenes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No scenes found for this range.'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: scenes.length,
                  itemBuilder: (context, i) {
                    final scene = scenes[i];
                    final cloudy = scene.cloudPct > 40;
                    final isFirstPick = _compareFirst?.id == scene.id;
                    return ListTile(
                      dense: true,
                      selected: isFirstPick,
                      leading: Icon(
                        isFirstPick
                            ? Icons.looks_one
                            : cloudy
                                ? Icons.cloud
                                : Icons.wb_sunny,
                        color: isFirstPick
                            ? Theme.of(context).colorScheme.primary
                            : cloudy
                                ? Colors.grey
                                : Colors.orange,
                      ),
                      title: Text(scene.dateLabel),
                      subtitle: Text(
                          '${scene.cloudPct.toStringAsFixed(0)}% cloud · ${scene.id}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      onTap: () => _onSceneTap(scene),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.geocoding});

  final GeocodingService geocoding;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _controller = TextEditingController();
  List<PlaceResult> _results = [];
  bool _searching = false;
  String? _error;

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.geocoding.search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _error = results.isEmpty ? 'No results found.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Search failed — check your connection.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Search location'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Place name or address',
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.search), onPressed: _search),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ),
            if (_results.isNotEmpty)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (context, i) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.place),
                    title: Text(_results[i].displayName,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(context).pop(_results[i]),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save project'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Project name'),
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
