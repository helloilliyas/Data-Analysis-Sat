import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// A saved land-area project. Raster outputs and reports are stored as files
/// under the app documents directory (see PLAN.md §3); only metadata and the
/// drawn polygon live in SQLite.
class Projects extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// GeoJSON Polygon geometry (closed ring, [lng, lat] order).
  TextColumn get areaGeoJson => text()();
  RealColumn get areaSqMeters => real()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [Projects])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'satellite_app'));

  /// For tests: run against an in-memory executor.
  AppDatabase.withExecutor(super.e);

  @override
  int get schemaVersion => 1;

  Stream<List<Project>> watchProjects() =>
      (select(projects)..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .watch();

  Future<Project> getProject(int id) =>
      (select(projects)..where((t) => t.id.equals(id))).getSingle();

  Future<int> insertProject({
    required String name,
    required String areaGeoJson,
    required double areaSqMeters,
  }) =>
      into(projects).insert(ProjectsCompanion.insert(
        name: name,
        areaGeoJson: areaGeoJson,
        areaSqMeters: areaSqMeters,
      ));

  Future<void> updateProjectArea({
    required int id,
    required String areaGeoJson,
    required double areaSqMeters,
  }) =>
      (update(projects)..where((t) => t.id.equals(id))).write(
        ProjectsCompanion(
          areaGeoJson: Value(areaGeoJson),
          areaSqMeters: Value(areaSqMeters),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<int> deleteProject(int id) =>
      (delete(projects)..where((t) => t.id.equals(id))).go();
}
