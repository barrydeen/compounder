import 'package:compounder/data/store.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/ui/settings.dart';
import 'package:compounder/ui/settings/about.dart';
import 'package:compounder/ui/settings/ai.dart';
import 'package:compounder/ui/settings/data.dart';
import 'package:compounder/ui/settings/goals.dart';
import 'package:compounder/ui/settings/health.dart';
import 'package:compounder/ui/settings/notifications.dart';
import 'package:compounder/ui/settings/training.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Health plugin stub: the Health Connect page probes availability in
/// initState, which must not touch platform channels.
class _StubHealthSource implements HealthSource {
  @override
  Future<void> configure() async {}

  @override
  Future<HealthConnectSdkStatus?> sdkStatus() async =>
      HealthConnectSdkStatus.sdkAvailable;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> install() async {}

  @override
  bool isTypeAvailable(HealthDataType type) => true;

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types) async => true;

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types) async => true;

  @override
  Future<bool> isHistoryAvailable() async => true;

  @override
  Future<bool> isHistoryAuthorized() async => false;

  @override
  Future<bool> requestHistoryAuthorization() async => true;

  @override
  Future<List<HealthDataPoint>> fetch({
    required HealthDataType type,
    required DateTime start,
    required DateTime end,
  }) async =>
      const [];

  @override
  Future<void> revokePermissions() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  // No isolate: the widget test's fake-async zone cannot receive messages from
  // a background isolate, so DB futures would never complete.
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;
  late HealthService health;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: inMemoryDatabasePath);
    health = HealthService(
      store: store,
      repository: HealthRepository(store.db),
      source: _StubHealthSource(),
    );
  });

  tearDown(() async {
    await store.db.close();
  });

  Future<void> pumpSettings(WidgetTester tester,
      {double textScale = 1.0, Size size = const Size(800, 2400)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: health),
        Provider.value(value: NotifyService()),
      ],
      child: MaterialApp(
        theme: CompounderTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pump();
  }

  testWidgets('Settings is a menu of categories that each open their page',
      (tester) async {
    await pumpSettings(tester);

    final pages = <String, Type>{
      'AI & coaching': AiSettingsScreen,
      'Units & training': TrainingSettingsScreen,
      'Daily goals': GoalsSettingsScreen,
      'Health Connect': HealthConnectSettingsScreen,
      'Notifications': NotificationsSettingsScreen,
      'Your data': DataSettingsScreen,
      'About': AboutSettingsScreen,
    };

    for (final entry in pages.entries) {
      expect(find.text(entry.key), findsOneWidget,
          reason: 'the hub must list ${entry.key}');
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(find.byType(entry.value, skipOffstage: false), findsOneWidget,
          reason: '${entry.key} must open ${entry.value}');
      // Return to the hub for the next category.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the settings menu does not overflow at 320dp/textScaler 2.0',
      (tester) async {
    await pumpSettings(tester, textScale: 2.0, size: const Size(320, 640));
    expect(tester.takeException(), isNull);

    // Scroll to the last item; any overflow while laying out the cards is
    // reported as a framework exception.
    await tester.scrollUntilVisible(find.text('About'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('About'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
