// Renders the main screens with sample data and saves PNGs to build/screens/ for review.
// Run: flutter test test/screens
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:fantikpay/app_state.dart';
import 'package:fantikpay/core/api.dart';
import 'package:fantikpay/core/errors.dart';
import 'package:fantikpay/core/ids.dart';
import 'package:fantikpay/core/storage.dart';
import 'package:fantikpay/core/theme.dart';
import 'package:fantikpay/data/bank.dart';
import 'package:fantikpay/data/db.dart';
import 'package:fantikpay/data/sync.dart';
import 'package:fantikpay/features/auth/login_screen.dart';
import 'package:fantikpay/features/family/home_screen.dart';
import 'package:fantikpay/features/game/lobby_screen.dart';
import 'package:fantikpay/features/game/new_game_screen.dart';
import 'package:fantikpay/features/game/op_screens.dart';
import 'package:fantikpay/features/game/results_screen.dart';
import 'package:fantikpay/features/game/terminal_screen.dart';
import 'package:fantikpay/nfc/card_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const spaceId = '00000000-0000-0000-0000-00000000000a';

/// No network in screenshot tests: every call fails fast as "offline".
class OfflineApi extends Api {
  OfflineApi(super.store);

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) => Future.error(const OfflineError());
  @override
  Future<dynamic> post(String path, [Object? body]) => Future.error(const OfflineError());
}

Future<void> loadFonts() async {
  for (final (family, weights) in [('Manrope', [400, 500, 600, 700, 800]), ('Unbounded', [500, 600, 700, 800])]) {
    final loader = FontLoader(family);
    for (final w in weights) {
      final bytes = File('assets/fonts/$family-$w.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }
  // Material icons for a realistic render.
  final icons = FontLoader('MaterialIcons');
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '/opt/sdk/flutter';
  final iconFile = File('$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (iconFile.existsSync()) {
    icons.addFont(Future.value(ByteData.view(iconFile.readAsBytesSync().buffer)));
    await icons.load();
  }
}

Future<(Services, Bank)> seed() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final db = AppDb.forWidgetTests();
  final store = MemoryStore();
  final api = OfflineApi(store);
  final sync = SyncService(db, api)..configure(spaceId: spaceId, deviceId: newId());
  await db.setMeta(SyncService.spaceKey(spaceId), '{"id":"$spaceId","name":"Моя семья","type":"family","currency_name":"монеты","role":"owner","daily_transfer_limit":100}');
  final names = {'Маша': '00000000-0000-0000-0000-000000000001', 'Тимур': '00000000-0000-0000-0000-000000000002', 'Соня': '00000000-0000-0000-0000-000000000003'};
  final balances = {'Маша': 340, 'Тимур': 125, 'Соня': 60};
  for (final e in names.entries) {
    await db.into(db.players).insert(PlayersCompanion.insert(id: e.value, spaceId: spaceId, name: e.key, linkedDevices: Value(e.key == 'Маша' ? 1 : 0)));
    await db.into(db.wallets).insert(WalletsCompanion.insert(
        id: persistentWalletId(e.value), spaceId: spaceId, kind: 'persistent', playerId: Value(e.value), serverBalance: Value(balances[e.key]!)));
    if (e.key != 'Тимур') {
      await db.into(db.cards).insert(CardsCompanion.insert(id: newId(), token: 'tok${e.key.hashCode}', status: 'active', playerId: Value(e.value)));
    }
  }
  await db.into(db.templates).insert(TemplatesCompanion.insert(
      id: 't1', name: 'Настольная экономическая игра', startingCapital: 1500,
      quickButtons: '[{"label":"50","amount":50,"type":"debit"},{"label":"100","amount":100,"type":"debit"},{"label":"За круг 200","amount":200,"type":"credit"}]'));
  final services = Services(store: store, db: db, api: api, sync: sync, reader: DebugCardReader(GlobalKey()), deviceId: sync.deviceId!, navigatorKey: GlobalKey());
  final bank = Bank(db: db, api: api, sync: sync, spaceId: spaceId, deviceId: sync.deviceId!);
  return (services, bank);
}

class FakeAuth extends AuthController {
  @override
  AuthState build() => AdultSession(
        user: const {'email': 'mama@mail.ru', 'name': 'Мама'},
        space: const SpaceInfo({'id': spaceId, 'name': 'Моя семья', 'type': 'family', 'role': 'owner', 'currency_name': 'монеты', 'daily_transfer_limit': 100}),
        spaces: const [],
      );
}

Future<void> shot(WidgetTester tester, Services services, Widget screen, String name) async {
  final key = GlobalKey();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      servicesProvider.overrideWithValue(services),
      authProvider.overrideWith(FakeAuth.new),
      allowancesProvider.overrideWith((ref) async => [
            {'id': 'a', 'comment': 'Карманные', 'weekday': 6, 'amount': 30},
          ]),
      pendingRequestsProvider.overrideWith((ref) async => []),
    ],
    child: RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
        home: screen,
      ),
    ),
  ));
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/screens').createSync(recursive: true);
    File('build/screens/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late Services services;
  late Bank bank;
  late String sessionId;

  setUpAll(() async {
    await initializeDateFormatting('ru');
    await loadFonts();
  });

  setUp(() async {
    (services, bank) = await seed();
  });

  tearDown(() => services.db.close());

  Future<void> sizeTo(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('login', (tester) async {
    await sizeTo(tester);
    await shot(tester, services, const LoginScreen(), '01_login');
  });

  testWidgets('family', (tester) async {
    await sizeTo(tester);
    await shot(tester, services, const HomeScreen(), '02_family');
  });

  testWidgets('new game', (tester) async {
    await sizeTo(tester);
    await shot(tester, services, const NewGameScreen(), '03_new_game');
  });

  testWidgets('lobby, terminal, results', (tester) async {
    await sizeTo(tester);
    await tester.runAsync(() async {
      sessionId = await bank.createSession(name: 'Настольная игра', moneyMode: 'reset', startingCapital: 1500,
          quickButtons: [const QuickButton('50', 50, 'debit'), const QuickButton('100', 100, 'debit'), const QuickButton('За круг 200', 200, 'credit')]);
      for (final p in await services.db.watchPlayers(spaceId).first) {
        await bank.join(sessionId, await bank.holderFor(p));
      }
    });
    await shot(tester, services, LobbyScreen(sessionId: sessionId), '04_lobby');
    await tester.runAsync(() async {
      await bank.setStatus(sessionId, 'active');
      final masha = (await services.db.watchPlayers(spaceId).first).firstWhere((p) => p.name == 'Маша');
      await bank.operate(type: 'debit', amount: 200, subject: await bank.holderFor(masha, sessionId: sessionId), sessionId: sessionId);
    });
    await shot(tester, services, TerminalScreen(sessionId: sessionId), '05_terminal');
    await shot(tester, services, ResultsScreen(sessionId: sessionId), '08_results');
  });

  testWidgets('operation screens', (tester) async {
    await sizeTo(tester);
    final masha = (await tester.runAsync(() => services.db.watchPlayers(spaceId).first))!.first;
    await shot(tester, services, OpResultScreen(done: OpDone(txId: 'x', type: 'debit', amount: 200, player: masha, balance: 1300, queued: true)), '06_op_done');
    await shot(tester, services, const InsufficientScreen(name: 'Тимур', balance: 150, amount: 200), '07_insufficient');
    await shot(tester, services, const CardRejectedScreen(code: 'card_blocked'), '09_card_blocked');
  });
}
