import 'package:flutter/material.dart';

import '../db/database.dart';
import '../services/processing_service.dart';

const kSettingServerUrl = 'server_url';
const kSettingApiKey = 'api_key';

Future<ProcessingConfig> loadProcessingConfig(AppDatabase db) async {
  return ProcessingConfig(
    baseUrl: await db.getSetting(kSettingServerUrl) ?? '',
    apiKey: await db.getSetting(kSettingApiKey) ?? '',
  );
}

/// Dialog for the processing server URL + API key (from `modal deploy`).
/// Returns the saved config, or null if cancelled.
Future<ProcessingConfig?> showServerSettingsDialog(
    BuildContext context, AppDatabase db) async {
  final current = await loadProcessingConfig(db);
  if (!context.mounted) return null;
  final saved = await showDialog<ProcessingConfig>(
    context: context,
    builder: (context) => _ServerSettingsDialog(initial: current),
  );
  if (saved != null) {
    await db.setSetting(kSettingServerUrl, saved.baseUrl);
    await db.setSetting(kSettingApiKey, saved.apiKey);
  }
  return saved;
}

class _ServerSettingsDialog extends StatefulWidget {
  const _ServerSettingsDialog({required this.initial});

  final ProcessingConfig initial;

  @override
  State<_ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<_ServerSettingsDialog> {
  late final _urlController = TextEditingController(text: widget.initial.baseUrl);
  late final _keyController = TextEditingController(text: widget.initial.apiKey);

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Processing server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Deploy the server with "modal deploy" (see server/README.md), '
            'then paste its URL and API key here.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://you--satellite-processor-web.modal.run',
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          TextField(
            controller: _keyController,
            decoration: const InputDecoration(labelText: 'API key'),
            autocorrect: false,
            obscureText: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ProcessingConfig(
            baseUrl: _urlController.text.trim(),
            apiKey: _keyController.text.trim(),
          )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
