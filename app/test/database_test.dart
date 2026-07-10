import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satellite_app/db/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.withExecutor(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  const geoJson =
      '{"type":"Polygon","coordinates":[[[0,0],[0.01,0],[0.01,0.01],[0,0]]]}';

  test('insert, read, update, delete a project', () async {
    final id = await db.insertProject(
      name: 'North field',
      areaGeoJson: geoJson,
      areaSqMeters: 12345,
    );

    var project = await db.getProject(id);
    expect(project.name, 'North field');
    expect(project.areaSqMeters, 12345);

    await db.updateProjectArea(
      id: id,
      areaGeoJson: geoJson,
      areaSqMeters: 54321,
    );
    project = await db.getProject(id);
    expect(project.areaSqMeters, 54321);

    await db.deleteProject(id);
    expect(await db.watchProjects().first, isEmpty);
  });

  test('watchProjects orders by most recently updated', () async {
    await db.insertProject(
        name: 'first', areaGeoJson: geoJson, areaSqMeters: 1);
    // Ensure a later updatedAt timestamp for the second row.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await db.insertProject(
        name: 'second', areaGeoJson: geoJson, areaSqMeters: 2);

    final projects = await db.watchProjects().first;
    expect(projects.map((p) => p.name), ['second', 'first']);
  });
}
