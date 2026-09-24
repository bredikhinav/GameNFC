import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'db.g.dart';

/// Local copy of the server state of one space, plus the queue of offline operations.
///
/// Balances shown to the user = the server balance of a wallet (as of the last sync)
/// + the effect of local transactions that the server has not confirmed yet (`pending`).

class Players extends Table {
  TextColumn get id => text()();
  TextColumn get spaceId => text()();
  TextColumn get name => text()();
  TextColumn get avatar => text().withDefault(const Constant('default'))();
  TextColumn get groupName => text().nullable()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get goalTitle => text().nullable()();
  IntColumn get goalTarget => integer().nullable()();
  IntColumn get linkedDevices => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('LocalCard')
class Cards extends Table {
  TextColumn get id => text()();
  TextColumn get token => text()();
  TextColumn get uid => text().nullable()();
  TextColumn get status => text()();
  TextColumn get playerId => text().nullable()();
  TextColumn get label => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Wallets extends Table {
  TextColumn get id => text()();
  TextColumn get spaceId => text()();
  TextColumn get kind => text()(); // persistent | session | bank | shop
  TextColumn get playerId => text().nullable()();
  TextColumn get sessionId => text().nullable()();
  IntColumn get serverBalance => integer().withDefault(const Constant(0))();
  BoolColumn get flagged => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('GameSession')
class GameSessions extends Table {
  TextColumn get id => text()();
  TextColumn get spaceId => text()();
  TextColumn get name => text()();
  TextColumn get moneyMode => text()(); // reset | persistent
  IntColumn get startingCapital => integer()();
  TextColumn get quickButtons => text().withDefault(const Constant('[]'))();
  TextColumn get status => text()(); // lobby | active | paused | finished
  TextColumn get deviceId => text().nullable()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get finishedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Participants extends Table {
  TextColumn get sessionId => text()();
  TextColumn get playerId => text()();
  TextColumn get walletId => text()();
  DateTimeColumn get joinedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {sessionId, playerId};
}

@DataClassName('Tx')
class Txs extends Table {
  TextColumn get id => text()();
  TextColumn get spaceId => text()();
  TextColumn get type => text()();
  TextColumn get fromWallet => text()();
  TextColumn get toWallet => text()();
  IntColumn get amount => integer()();
  TextColumn get sessionId => text().nullable()();
  TextColumn get reversesId => text().nullable()();
  TextColumn get comment => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get pending => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Offline queue, sent in order by `POST /sync`.
@DataClassName('OutboxItem')
class Outbox extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get spaceId => text()();
  TextColumn get kind => text()();
  TextColumn get payload => text()(); // JSON of the sync op
  TextColumn get txId => text().nullable()(); // local transaction created by this op
  TextColumn get state => text().withDefault(const Constant('pending'))(); // pending | failed
  TextColumn get error => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
}

class Templates extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get startingCapital => integer()();
  TextColumn get quickButtons => text()();
  BoolColumn get builtin => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

class Meta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Players, Cards, Wallets, GameSessions, Participants, Txs, Outbox, Templates, Meta])
class AppDb extends _$AppDb {
  AppDb(super.e);

  AppDb.memory() : super(NativeDatabase.memory());

  /// For widget tests: stream queries must not leave timers behind.
  AppDb.forWidgetTests() : super(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));

  static Future<AppDb> open() async {
    final dir = await getApplicationSupportDirectory();
    return AppDb(NativeDatabase.createInBackground(File(p.join(dir.path, 'fantikpay.sqlite'))));
  }

  @override
  int get schemaVersion => 1;

  // --- key-value -------------------------------------------------------------------

  Future<String?> getMeta(String key) async =>
      (await (select(meta)..where((m) => m.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setMeta(String key, String value) =>
      into(meta).insertOnConflictUpdate(MetaCompanion.insert(key: key, value: value));

  Future<void> wipe() => transaction(() async {
        for (final table in allTables) {
          await delete(table).go();
        }
      });

  // --- balances ----------------------------------------------------------------------

  static const _balanceSql = '''
    SELECT w.id AS id,
      w.server_balance
      + COALESCE((SELECT SUM(amount) FROM txs WHERE pending = 1 AND to_wallet = w.id), 0)
      - COALESCE((SELECT SUM(amount) FROM txs WHERE pending = 1 AND from_wallet = w.id), 0)
      AS balance
    FROM wallets w''';

  Selectable<({String id, int balance})> _balances(String where, List<Variable> vars) =>
      customSelect('$_balanceSql $where', variables: vars, readsFrom: {wallets, txs})
          .map((r) => (id: r.read<String>('id'), balance: r.read<int>('balance')));

  Future<int> balanceOf(String walletId) async =>
      (await _balances('WHERE w.id = ?', [Variable(walletId)]).getSingleOrNull())?.balance ?? 0;

  Stream<int> watchBalance(String walletId) =>
      _balances('WHERE w.id = ?', [Variable(walletId)]).watchSingleOrNull().map((r) => r?.balance ?? 0);

  Stream<Map<String, int>> watchBalances(String spaceId) =>
      _balances('WHERE w.space_id = ?', [Variable(spaceId)])
          .watch()
          .map((rows) => {for (final r in rows) r.id: r.balance});

  Future<int> pendingOut(String walletId) async {
    final sum = txs.amount.sum();
    final row = await (selectOnly(txs)
          ..addColumns([sum])
          ..where(txs.pending.equals(true) & txs.fromWallet.equals(walletId)))
        .getSingle();
    return row.read(sum) ?? 0;
  }

  // --- lookups -----------------------------------------------------------------------

  Stream<List<Player>> watchPlayers(String spaceId) => (select(players)
        ..where((p) => p.spaceId.equals(spaceId) & p.deleted.equals(false))
        ..orderBy([(p) => OrderingTerm(expression: p.name)]))
      .watch();

  Future<Player?> playerById(String id) => (select(players)..where((p) => p.id.equals(id))).getSingleOrNull();

  Future<LocalCard?> cardByToken(String token) =>
      (select(cards)..where((c) => c.token.equals(token))).getSingleOrNull();

  Future<LocalCard?> cardByUid(String uid) =>
      (select(cards)..where((c) => c.uid.equals(uid.toUpperCase()))).getSingleOrNull();

  Stream<List<LocalCard>> watchCards(String playerId) => (select(cards)
        ..where((c) => c.playerId.equals(playerId) & c.status.isIn(['active', 'blocked'])))
      .watch();

  Future<GameSession?> sessionById(String id) =>
      (select(gameSessions)..where((s) => s.id.equals(id))).getSingleOrNull();

  Stream<GameSession?> watchSession(String id) =>
      (select(gameSessions)..where((s) => s.id.equals(id))).watchSingleOrNull();

  Stream<List<GameSession>> watchSessions(String spaceId) => (select(gameSessions)
        ..where((s) => s.spaceId.equals(spaceId))
        ..orderBy([(s) => OrderingTerm.desc(s.createdAt)])
        ..limit(50))
      .watch();

  Future<Participant?> participant(String sessionId, String playerId) => (select(participants)
        ..where((x) => x.sessionId.equals(sessionId) & x.playerId.equals(playerId)))
      .getSingleOrNull();

  Stream<List<Participant>> watchParticipants(String sessionId) => (select(participants)
        ..where((x) => x.sessionId.equals(sessionId))
        ..orderBy([(x) => OrderingTerm(expression: x.joinedAt)]))
      .watch();

  Stream<int> watchOutboxCount(String spaceId) {
    final count = outbox.seq.count();
    return (selectOnly(outbox)
          ..addColumns([count])
          ..where(outbox.spaceId.equals(spaceId) & outbox.state.equals('pending')))
        .watchSingle()
        .map((r) => r.read(count) ?? 0);
  }

  Stream<List<OutboxItem>> watchFailed(String spaceId) => (select(outbox)
        ..where((o) => o.spaceId.equals(spaceId) & o.state.equals('failed')))
      .watch();

  Stream<List<Tx>> watchSpaceHistory(String spaceId, {int limit = 100}) => (select(txs)
        ..where((t) => t.spaceId.equals(spaceId))
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
        ..limit(limit))
      .watch();

  Stream<List<Tx>> watchWalletHistory(List<String> walletIds, {int limit = 100}) => (select(txs)
        ..where((t) => t.fromWallet.isIn(walletIds) | t.toWallet.isIn(walletIds))
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
        ..limit(limit))
      .watch();

  Future<List<Tx>> sessionTxs(String sessionId) =>
      (select(txs)..where((t) => t.sessionId.equals(sessionId))).get();
}
