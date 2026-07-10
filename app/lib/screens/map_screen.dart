import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../db/database.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart';
import '../utils/geo.dart';

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
            child: _EditPanel(
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
