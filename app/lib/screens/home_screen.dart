import 'package:flutter/material.dart';

import '../db/database.dart';
import '../utils/geo.dart';
import '../widgets/server_settings_dialog.dart';
import 'map_screen.dart';

/// Project list. Each project is a saved land area; Phase 2 adds imagery and
/// analysis per project.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Satellite Land Analysis'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Processing server settings',
            onPressed: () => showServerSettingsDialog(context, db),
          ),
        ],
      ),
      body: StreamBuilder<List<Project>>(
        stream: db.watchProjects(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final projects = snapshot.data!;
          if (projects.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.satellite_alt, size: 56, color: Colors.grey),
                  SizedBox(height: 12),
                  Text('No projects yet'),
                  SizedBox(height: 4),
                  Text('Tap + to draw your first land area',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }
          return ListView.builder(
            itemCount: projects.length,
            itemBuilder: (context, i) =>
                _ProjectTile(db: db, project: projects[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New area'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => MapScreen(db: db)),
        ),
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({required this.db, required this.project});

  final AppDatabase db;
  final Project project;

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${project.name}"?'),
        content: const Text('This removes the project and its saved area.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await db.deleteProject(project.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final updated = project.updatedAt.toLocal();
    final dateLabel = '${updated.year}-'
        '${updated.month.toString().padLeft(2, '0')}-'
        '${updated.day.toString().padLeft(2, '0')}';
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.crop_square)),
      title: Text(project.name),
      subtitle: Text('${formatArea(project.areaSqMeters)} · updated $dateLabel'),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'delete') _confirmDelete(context);
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MapScreen(db: db, project: project)),
      ),
    );
  }
}
