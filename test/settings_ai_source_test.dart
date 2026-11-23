import 'package:compounder/data/store.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/subscription/entitlement.dart';
import 'package:compounder/ui/settings.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// The BYO endpoint fields must only appear when the user has actually chosen
/// "Your own endpoint" — otherwise Settings shows two source choices plus a
/// form for a source that is not in use.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dbPath;
  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dbPath = '${await databaseFactory.getDatabasesPath()}/settings_ai.db';
    await databaseFactory.deleteDatabase(dbPath);
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: dbPath);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final health = HealthService(
      store: store,
      repository: HealthRepository(store.db),
      source: _StubHealthSource(),
    );
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: health),
        Provider.value(value: NotifyService()),
      ],
      child: MaterialApp(
        theme: CompounderTheme.light(),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump();
    // Settings is a two-step menu: open the AI page before asserting on it.
    await tester.tap(find.text('AI & coaching'));
    await tester.pumpAndSettle();
  }

  testWidgets('BYO endpoint fields are hidden while the gateway is selected',
      (tester) async {
    await store.setAiSource(AiSource.compounder);
    await pumpSettings(tester);

    expect(find.text('YOUR OWN ENDPOINT'), findsNothing);
    expect(find.widgetWithText(TextField, 'Base URL'), findsNothing);
    expect(find.widgetWithText(TextField, 'API token'), findsNothing);
    expect(find.widgetWithText(TextField, 'Model'), findsNothing);
    expect(find.text('Save AI settings'), findsNothing);
  });

  testWidgets('selecting the BYO radio reveals the endpoint fields',
      (tester) async {
    await store.setAiSource(AiSource.compounder);
    await pumpSettings(tester);

    await tester.tap(find.text('Your own endpoint (BYO)'));
    await tester.pumpAndSettle();

    expect(store.aiSource, AiSource.byo);
    expect(find.text('YOUR OWN ENDPOINT'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Base URL'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'API token'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Model'), findsOneWidget);
    expect(find.text('Save AI settings'), findsOneWidget);
  });

  testWidgets('selecting the gateway hides the endpoint fields again',
      (tester) async {
    await pumpSettings(tester);
    expect(find.widgetWithText(TextField, 'Base URL'), findsOneWidget);

    await tester.tap(find.text('Compounder AI (subscription)'));
    await tester.pumpAndSettle();

    expect(store.aiSource, AiSource.compounder);
    expect(find.widgetWithText(TextField, 'Base URL'), findsNothing);
    expect(find.text('YOUR OWN ENDPOINT'), findsNothing);
  });
}
