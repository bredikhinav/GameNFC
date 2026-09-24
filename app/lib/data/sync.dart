import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/api.dart';
import '../core/errors.dart';
import 'db.dart';

class SyncReport {
  const SyncReport({this.sent = 0, this.failed = 0, this.offline = false});

  final int sent;
  final int failed;
  final bool offline;
}

/// Sends the offline queue with `POST /sync` and applies server changes to the local copy.
class SyncService {
  SyncService(this.db, this.api);

  final AppDb db;
  final Api api;

  Future<SyncReport>? _running;
  bool _again = false;

  final _online = StreamController<bool>.broadcast();
  bool online = true;
  DateTime? lastSync;

  Stream<bool> get onlineChanges => _online.stream;

  String? spaceId;
  String? deviceId;
  String deviceName = '';

  void configure({required String spaceId, required String deviceId, String deviceName = ''}) {
    this.spaceId = spaceId;
    this.deviceId = deviceId;
    this.deviceName = deviceName;
  }

  static String cursorKey(String spaceId) => 'cursor:$spaceId';
  static String spaceKey(String spaceId) => 'space:$spaceId';

  /// Fire-and-forget sync after a local change.
  void kick() => unawaited(sync().catchError((_) => const SyncReport(offline: true)));

  /// Waits for a running sync (used before undoing an operation that may be in flight).
  Future<void> idle() async {
    while (_running != null) {
      await _running!.catchError((_) => const SyncReport());
    }
  }

  Future<SyncReport> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    final run = _loop();
    _running = run;
    return run.whenComplete(() => _running = null);
  }

  Future<SyncReport> _loop() async {
    var sent = 0, failed = 0;
    do {
      _again = false;
      final report = await _run();
      sent += report.sent;
      failed += report.failed;
      if (report.offline) return SyncReport(sent: sent, failed: failed, offline: true);
    } while (_again);
    return SyncReport(sent: sent, failed: failed);
  }

  void _setOnline(bool value) {
    if (online != value) {
      online = value;
      _online.add(value);
    }
  }

  Future<SyncReport> _run() async {
    final space = spaceId, device = deviceId;
    if (space == null || device == null) return const SyncReport();
    var sent = 0, failed = 0;
    while (true) {
      final items = await (db.select(db.outbox)
            ..where((o) => o.spaceId.equals(space) & o.state.equals('pending'))
            ..orderBy([(o) => OrderingTerm(expression: o.seq)])
            ..limit(200))
          .get();
      final cursor = int.tryParse(await db.getMeta(cursorKey(space)) ?? '') ?? 0;
      final Map<String, dynamic> res;
      try {
        res = await api.post('/sync', {
          'space_id': space,
          'device_id': device,
          'device_name': deviceName,
          'cursor': cursor,
          'ops': [for (final i in items) jsonDecode(i.payload)],
        }) as Map<String, dynamic>;
      } on OfflineError {
        _setOnline(false);
        return SyncReport(sent: sent, failed: failed, offline: true);
      }
      _setOnline(true);
      final results = (res['results'] as List).cast<Map<String, dynamic>>();
      final refetch = <String>{};
      await db.transaction(() async {
        for (final r in results) {
          final item = items[r['index'] as int];
          if (r['ok'] == true) {
            await (db.delete(db.outbox)..where((o) => o.seq.equals(item.seq))).go();
            sent++;
          } else {
            failed++;
            await (db.update(db.outbox)..where((o) => o.seq.equals(item.seq)))
                .write(OutboxCompanion(state: const Value('failed'), error: Value(r['error'] as String?)));
            final sessionId = await _revert(item);
            if (sessionId != null) refetch.add(sessionId);
          }
        }
        await applyChanges(space, res['changes'] as Map<String, dynamic>);
        await db.setMeta(cursorKey(space), '${res['cursor']}');
      });
      for (final id in refetch) {
        await _refetchSession(id);
      }
      lastSync = DateTime.now();
      final more = res['has_more'] == true;
      final queued = await (db.select(db.outbox)
            ..where((o) => o.spaceId.equals(space) & o.state.equals('pending'))
            ..limit(1))
          .get();
      if (!more && queued.isEmpty) return SyncReport(sent: sent, failed: failed);
    }
  }

  /// Undo the local effect of an op the server rejected. Returns a session to re-read.
  Future<String?> _revert(OutboxItem item) async {
    final op = jsonDecode(item.payload) as Map<String, dynamic>;
    if (item.txId != null) {
      await (db.delete(db.txs)..where((t) => t.id.equals(item.txId!) & t.pending.equals(true))).go();
    }
    switch (item.kind) {
      case 'session.create':
        final id = (op['session'] as Map)['id'] as String;
        await (db.delete(db.participants)..where((p) => p.sessionId.equals(id))).go();
        await (db.delete(db.txs)..where((t) => t.sessionId.equals(id) & t.pending.equals(true))).go();
        await (db.delete(db.wallets)..where((w) => w.sessionId.equals(id) & w.serverBalance.equals(0))).go();
        await (db.delete(db.gameSessions)..where((s) => s.id.equals(id))).go();
        return null;
      case 'session.join':
        final sessionId = op['session_id'] as String;
        final playerId = (op['join'] as Map)['player_id'] as String?;
        if (playerId != null) {
          await (db.delete(db.participants)
                ..where((p) => p.sessionId.equals(sessionId) & p.playerId.equals(playerId)))
              .go();
        }
        return sessionId;
      case 'session.status':
      case 'session.finish':
        return op['session_id'] as String;
    }
    return null;
  }

  Future<void> _refetchSession(String id) async {
    try {
      final s = await api.get('/sessions/$id') as Map<String, dynamic>;
      await db.into(db.gameSessions).insertOnConflictUpdate(_session(s));
    } on Exception {
      // The next sync brings the state anyway.
    }
  }

  static GameSessionsCompanion _session(Map<String, dynamic> s) => GameSessionsCompanion.insert(
        id: s['id'] as String,
        spaceId: s['space_id'] as String,
        name: s['name'] as String,
        moneyMode: s['money_mode'] as String,
        startingCapital: s['starting_capital'] as int,
        quickButtons: Value(jsonEncode(s['quick_buttons'] ?? [])),
        status: s['status'] as String,
        deviceId: Value(s['device_id'] as String?),
        startedAt: Value(_date(s['started_at'])),
        finishedAt: Value(_date(s['finished_at'])),
        createdAt: _date(s['created_at'])!,
      );

  static DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

  /// Apply a `changes` object from `POST /sync` (also used after online calls).
  Future<void> applyChanges(String spaceId, Map<String, dynamic> c) async {
    if (c['space'] != null) await db.setMeta(spaceKey(spaceId), jsonEncode(c['space']));
    await db.batch((b) {
      for (final p in (c['players'] as List? ?? []).cast<Map<String, dynamic>>()) {
        b.insert(db.players, playerRow(p), mode: InsertMode.insertOrReplace);
      }
      for (final x in (c['cards'] as List? ?? []).cast<Map<String, dynamic>>()) {
        b.insert(
          db.cards,
          CardsCompanion.insert(
            id: x['id'] as String,
            token: x['token'] as String,
            uid: Value(x['uid'] as String?),
            status: x['status'] as String,
            playerId: Value(x['player_id'] as String?),
            label: Value(x['label'] as String?),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
      for (final w in (c['wallets'] as List? ?? []).cast<Map<String, dynamic>>()) {
        b.insert(
          db.wallets,
          WalletsCompanion.insert(
            id: w['wallet_id'] as String,
            spaceId: spaceId,
            kind: w['kind'] as String,
            playerId: Value(w['player_id'] as String?),
            sessionId: Value(w['session_id'] as String?),
            serverBalance: Value(w['balance'] as int),
            flagged: Value(w['flagged'] as bool? ?? false),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
      for (final s in (c['sessions'] as List? ?? []).cast<Map<String, dynamic>>()) {
        b.insert(db.gameSessions, _session(s), mode: InsertMode.insertOrReplace);
      }
      for (final p in (c['participants'] as List? ?? []).cast<Map<String, dynamic>>()) {
        b.insert(
          db.participants,
          ParticipantsCompanion.insert(
            sessionId: p['session_id'] as String,
            playerId: p['player_id'] as String,
            walletId: p['wallet_id'] as String,
            joinedAt: DateTime.parse(p['joined_at'] as String),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
      for (final t in (c['transactions'] as List? ?? []).cast<Map<String, dynamic>>()) {
        b.insert(
          db.txs,
          TxsCompanion.insert(
            id: t['id'] as String,
            spaceId: t['space_id'] as String,
            type: t['type'] as String,
            fromWallet: t['from_wallet_id'] as String,
            toWallet: t['to_wallet_id'] as String,
            amount: t['amount'] as int,
            sessionId: Value(t['session_id'] as String?),
            reversesId: Value(t['reverses_id'] as String?),
            comment: Value(t['comment'] as String?),
            createdAt: DateTime.parse(t['created_at'] as String),
            pending: const Value(false),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
      final templates = (c['templates'] as List? ?? []).cast<Map<String, dynamic>>();
      for (final t in templates) {
        b.insert(
          db.templates,
          TemplatesCompanion.insert(
            id: t['id'] as String,
            name: t['name'] as String,
            startingCapital: t['starting_capital'] as int,
            quickButtons: jsonEncode(t['quick_buttons']),
            builtin: Value(t['builtin'] as bool? ?? false),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  static PlayersCompanion playerRow(Map<String, dynamic> p) {
    final goal = p['goal'] as Map<String, dynamic>?;
    return PlayersCompanion.insert(
      id: p['id'] as String,
      spaceId: p['space_id'] as String,
      name: p['name'] as String,
      avatar: Value(p['avatar'] as String? ?? 'default'),
      groupName: Value(p['group_name'] as String?),
      deleted: Value(p['deleted'] as bool? ?? false),
      goalTitle: Value(goal?['title'] as String?),
      goalTarget: Value(goal?['target_amount'] as int?),
      linkedDevices: Value(p['linked_devices'] as int? ?? 0),
    );
  }
}
