import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/store.dart';
import '../../subscription/entitlement.dart';
import '../../subscription/service.dart';
import '../subscription.dart';
import '../widgets.dart';

/// AI source and BYO endpoint settings, reached from the Settings menu.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final TextEditingController baseUrl;
  late final TextEditingController apiKey;
  late final TextEditingController model;
  bool showApiKey = false;

  @override
  void initState() {
    super.initState();
    final ai = context.read<AppStore>().ai;
    baseUrl = TextEditingController(text: ai.baseUrl);
    apiKey = TextEditingController(text: ai.apiKey);
    model = TextEditingController(text: ai.model);
  }

  @override
  void dispose() {
    for (final c in [baseUrl, apiKey, model]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    // Optional: the subscription service is only provided by the real app, so
    // widget tests that pump this screen alone still work.
    final subscription = context.watch<SubscriptionService?>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    void snack(String text) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));

    void openSubscription() {
      final service = subscription;
      if (service == null) return;
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SubscriptionScreen(service: service)));
    }

    final entitlement = store.entitlement;
    final subscribed = entitlement?.isActiveAt(DateTime.now()) ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('AI & coaching')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionHeader('AI source'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Column(children: [
              RadioGroup<AiSource>(
                groupValue: store.aiSource,
                onChanged: (value) async {
                  if (value == null) return;
                  await store.setAiSource(value);
                },
                child: Column(children: [
                  RadioListTile<AiSource>(
                    value: AiSource.compounder,
                    title: const Text('Compounder AI (subscription)'),
                    subtitle:
                        Text(entitlementSummary(entitlement, DateTime.now())),
                  ),
                  RadioListTile<AiSource>(
                    value: AiSource.byo,
                    title: const Text('Your own endpoint (BYO)'),
                    subtitle: const Text(
                        'Free and unlimited. Uses the endpoint configured below.'),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: subscription == null ? null : openSubscription,
                      child: Text(subscribed
                          ? 'Manage subscription'
                          : 'View Compounder AI plans'),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
          if (store.aiSource == AiSource.byo) ...[
            const SizedBox(height: 16),
            const SectionHeader('Your own endpoint'),
            const SizedBox(height: 8),
            Card(
              color: scheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  Text(
                      'This endpoint powers meal photo analysis and the coach. '
                      'Data is sent only to this endpoint — never anywhere '
                      'else.',
                      style: t.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  TextField(
                      controller: baseUrl,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                          labelText: 'Base URL', hintText: 'http://…/v1')),
                  // The app allows cleartext HTTP (AndroidManifest
                  // usesCleartextTraffic="true") so a LAN Ollama endpoint works.
                  // Say so where the endpoint is entered: over http:// the token
                  // and every prompt travel unencrypted (audit m6).
                  if (baseUrl.text
                      .trim()
                      .toLowerCase()
                      .startsWith('http://')) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Icon(Icons.lock_open, size: 16, color: scheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                            'This endpoint is http://, so your API token and '
                            'health data travel unencrypted. Use https:// or a '
                            'trusted local network.',
                            style: t.bodySmall?.copyWith(color: scheme.error)),
                      ),
                    ]),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: apiKey,
                    obscureText: !showApiKey,
                    decoration: InputDecoration(
                      labelText: 'API token',
                      suffixIcon: IconButton(
                        icon: Icon(showApiKey
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () =>
                            setState(() => showApiKey = !showApiKey),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                      controller: model,
                      decoration: const InputDecoration(
                          labelText: 'Model',
                          hintText: 'any vision + tool-calling model')),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      await store.saveAi(AiSettings(
                        baseUrl: baseUrl.text.trim(),
                        apiKey: apiKey.text.trim(),
                        model: model.text.trim(),
                      ));
                      if (context.mounted) snack('AI settings saved');
                    },
                    child: const Text('Save AI settings'),
                  ),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
