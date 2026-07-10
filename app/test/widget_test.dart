import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satellite_app/db/database.dart';
import 'package:satellite_app/main.dart';

void main() {
  testWidgets('home screen shows empty state, then a saved project',
      (tester) async {
    final db = AppDatabase.withExecutor(NativeDatabase.memory());

    await tester.pumpWidget(SatelliteApp(db: db));
    // Drift streams complete on the real event loop, which testWidgets'
    // fake-async zone doesn't drive — flush it with runAsync, then pump.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('No projects yet'), findsOneWidget);
    expect(find.text('New area'), findsOneWidget);

    await tester.runAsync(() => db.insertProject(
          name: 'Test field',
          areaGeoJson:
              '{"type":"Polygon","coordinates":[[[0,0],[0.01,0],[0.01,0.01],[0,0]]]}',
          areaSqMeters: 25000,
        ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('Test field'), findsOneWidget);
    expect(find.textContaining('2.50 ha'), findsOneWidget);

    // Tear down inside the test body: dispose the tree, let drift's
    // stream-eviction timer fire on the fake clock, then close the db —
    // otherwise the binding fails the test with "A Timer is still pending".
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    await tester.runAsync(db.close);
  });
}
