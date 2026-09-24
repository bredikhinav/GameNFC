// End-to-end check of the offline engine (Bank + SyncService) against a running API.
//
//   cd server && uv run uvicorn app.main:app --port 8765
//   cd app && flutter test test/bank_integration_test.dart --dart-define=API_URL=http://localhost:8765
//
// Skipped when API_URL is not given.
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fantikpay/core/api.dart';
import 'package:fantikpay/core/errors.dart';
import 'package:fantikpay/core/ids.dart';
import 'package:fantikpay/core/storage.dart';
import 'package:fantikpay/data/bank.dart';
import 'package:fantikpay/data/db.dart';
import 'package:fantikpay/data/sync.dart';
import 'package:flutter_test/flutter_test.dart';

const apiUrl = String.fromEnvironment('API_URL');

/// An API client whose network can be switched off.
class FlakyApi extends Api {
  FlakyApi(super.store) : super(baseUrl: '$apiUrl/api/v1');

  bool offline = false;

  @override
  Future<dynamic> post(String path, [Object? body]) => offline ? Future.error(const OfflineError()) : super.post(path, body);

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      offline ? Future.error(const OfflineError()) : super.get(path, query: query);
}

void main() {
  if (apiUrl.isEmpty) {
    test('bank integration', () {}, skip: 'pass --dart-define=API_URL=http://localhost:8765');
    return;
  }
  late FlakyApi api;
  late AppDb db;
  late SyncService sync;
  late Bank bank;
  late String spaceId, mashaId, timurId, mashaCard, timurCard;

  setUp(() async {
    final store = MemoryStore();
    api = FlakyApi(store);
    final email = 'it-${newId().substring(0, 8)}@example.com';
    await api.saveTokens(await api.post('/auth/register', {'email': email, 'password': 'password123'}) as Map<String, dynamic>);
    spaceId = (await api.post('/spaces', {'name': 'Тест'}) as Map)['id'] as String;
    Future<String> player(String name) async =>
        (await api.post('/spaces/$spaceId/players', {'name': name, 'consent': true}) as Map)['id'] as String;
    Future<String> card(String playerId) async {
      final token = (await api.post('/cards/prepare') as Map)['token'] as String;
      await api.post('/cards/activate', {'token': token, 'player_id': playerId});
      return token;
    }

    mashaId = await player('Маша');
    timurId = await player('Тимур');
    mashaCard = await card(mashaId);
    timurCard = await card(timurId);

    db = AppDb.memory();
    sync = SyncService(db, api)..configure(spaceId: spaceId, deviceId: newId());
    bank = Bank(db: db, api: api, sync: sync, spaceId: spaceId, deviceId: sync.deviceId!);
    await sync.sync();
  });

  tearDown(() => db.close());

  Future<int> serverBalance(String playerId) async {
    final players = await api.get('/spaces/$spaceId/players') as List;
    return (players.firstWhere((p) => p['id'] == playerId) as Map)['balance'] as int;
  }

  test('game offline on one terminal, then sync matches the server exactly', () async {
    expect((await db.watchPlayers(spaceId).first).map((p) => p.name), ['Маша', 'Тимур']);

    api.offline = true;
    final sessionId = await bank.createSession(name: 'Настольная', moneyMode: 'reset', startingCapital: 1500);
    final masha = await bank.identify(CardTap(token: mashaCard));
    final timur = await bank.identify(CardTap(token: timurCard));
    expect(await bank.join(sessionId, masha), isTrue);
    expect(await bank.join(sessionId, timur), isTrue);
    expect(await bank.join(sessionId, masha), isFalse);
    await bank.setStatus(sessionId, 'active');

    final inGame = await bank.identify(CardTap(token: mashaCard), sessionId: sessionId);
    expect(inGame.balance, 1500);
    final paid = await bank.operate(type: 'debit', amount: 200, subject: inGame, sessionId: sessionId);
    expect(paid.balance, 1300);
    expect(paid.queued, isTrue);
    await bank.operate(
      type: 'transfer',
      amount: 100,
      subject: await bank.identify(CardTap(token: mashaCard), sessionId: sessionId),
      receiver: await bank.identify(CardTap(token: timurCard), sessionId: sessionId),
      sessionId: sessionId,
    );
    await expectLater(
      bank.operate(type: 'debit', amount: 5000, subject: inGame, sessionId: sessionId),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'insufficient_funds')),
    );
    final local = await bank.standings(sessionId);
    expect([for (final s in local) (s.player.name, s.balance)], [('Тимур', 1600), ('Маша', 1200)]);
    await bank.finish(sessionId, prizes: {timurId: 20});

    // Back online: the queue goes out in order and the local copy equals the server.
    api.offline = false;
    final report = await sync.sync();
    expect(report.failed, 0);
    expect(await db.watchOutboxCount(spaceId).first, 0);
    final pending = await (db.select(db.txs)..where((t) => t.pending.equals(true))).get();
    expect(pending, isEmpty);

    final server = await api.get('/sessions/$sessionId') as Map<String, dynamic>;
    expect(server['status'], 'finished');
    expect([for (final s in server['standings'] as List) (s['name'], s['balance'])], [('Тимур', 1600), ('Маша', 1200)]);
    expect(await serverBalance(timurId), 20);
    expect(await db.balanceOf(persistentWalletId(timurId)), 20);
    expect(await db.balanceOf(sessionWalletId(sessionId, mashaId)), 1200);
  });

  test('undo: a queued operation is dropped, a sent one is reversed', () async {
    final masha = await bank.identify(CardTap(token: mashaCard));

    api.offline = true;
    final queued = await bank.operate(type: 'credit', amount: 50, subject: masha);
    await bank.undo(queued.txId);
    expect(await db.watchOutboxCount(spaceId).first, 0);
    expect(await db.balanceOf(persistentWalletId(mashaId)), 0);

    api.offline = false;
    final sent = await bank.operate(type: 'credit', amount: 70, subject: masha, comment: 'Уборка');
    await sync.idle();
    await sync.sync();
    expect(await serverBalance(mashaId), 70);
    await bank.setComment(sent.txId, 'Уборка в комнате');
    await bank.undo(sent.txId);
    await sync.idle();
    await sync.sync();
    expect(await serverBalance(mashaId), 0);
    expect(await db.balanceOf(persistentWalletId(mashaId)), 0);
    await expectLater(bank.undo(sent.txId), throwsA(isA<ApiError>()));
  });

  test('a card blocked on another phone is rejected after the next sync', () async {
    final cardId = ((await api.post('/cards/resolve', {'space_id': spaceId, 'token': timurCard}) as Map)['card'] as Map)['id'];
    await api.post('/cards/$cardId/block');
    await sync.sync();
    await expectLater(
      bank.identify(CardTap(token: timurCard)),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'card_blocked')),
    );
  });

  test('two terminals: offline overdraft is accepted and flagged', () async {
    await bank.operate(type: 'credit', amount: 40, subject: await bank.identify(CardTap(token: mashaCard)));
    await sync.idle();
    await sync.sync();

    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db2 = AppDb.memory();
    final sync2 = SyncService(db2, api)..configure(spaceId: spaceId, deviceId: newId());
    final bank2 = Bank(db: db2, api: api, sync: sync2, spaceId: spaceId, deviceId: sync2.deviceId!);
    await sync2.sync();

    api.offline = true;
    await bank.operate(type: 'debit', amount: 30, subject: await bank.identify(CardTap(token: mashaCard)));
    await bank2.operate(type: 'debit', amount: 30, subject: await bank2.identify(CardTap(token: mashaCard)));
    api.offline = false;
    await sync.sync();
    await sync2.sync();
    await sync.sync();

    expect(await serverBalance(mashaId), -20);
    expect(await db.balanceOf(persistentWalletId(mashaId)), -20);
    final wallet = await (db.select(db.wallets)..where((w) => w.id.equals(persistentWalletId(mashaId)))).getSingle();
    expect(wallet.flagged, isTrue);
    await db2.close();
  });

  test('network errors never lose operations', () async {
    final dead = SyncService(db, Api(MemoryStore(), dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9/api/v1'))))
      ..configure(spaceId: spaceId, deviceId: sync.deviceId!);
    final offlineBank = Bank(db: db, api: dead.api, sync: dead, spaceId: spaceId, deviceId: sync.deviceId!);
    await offlineBank.operate(type: 'credit', amount: 10, subject: await offlineBank.identify(CardTap(token: mashaCard)));
    final r = await dead.sync();
    expect(r.offline, isTrue);
    expect(await db.watchOutboxCount(spaceId).first, 1);
    await sync.sync();
    expect(await db.watchOutboxCount(spaceId).first, 0);
    expect(await serverBalance(mashaId), 10);
  });
}
