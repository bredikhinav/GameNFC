import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/api.dart';
import '../core/errors.dart';
import '../core/ids.dart';
import 'db.dart';
import 'sync.dart';

/// What a card tap gives: the token from the NDEF link and/or the chip UID.
class CardTap {
  const CardTap({this.token, this.uid});

  final String? token;
  final String? uid;

  @override
  String toString() => 'CardTap($token, $uid)';
}

/// A player identified by a tap (or chosen from the list), with the wallet in use.
class Holder {
  const Holder({required this.player, required this.walletId, required this.balance, this.card});

  final Player player;
  final LocalCard? card;
  final String walletId;
  final int balance;
}

class SpaceInfo {
  const SpaceInfo(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get type => json['type'] as String;
  bool get isOrganization => type == 'organization';
  String get currencyName => json['currency_name'] as String? ?? 'монеты';
  String get currencyIcon => json['currency_icon'] as String? ?? '🪙';
  bool get allowNegative => json['allow_negative'] as bool? ?? false;
  int? get dailyTransferLimit => json['daily_transfer_limit'] as int?;
  int? get approvalThreshold => json['transfer_approval_threshold'] as int?;
  int? get offlineSpendLimit => json['offline_spend_limit'] as int?;
  String? get role => json['role'] as String?;
  bool get isAdmin => role == 'owner' || role == 'admin';
}

class QuickButton {
  const QuickButton(this.label, this.amount, this.type);

  final String label;
  final int amount;
  final String type; // credit | debit

  factory QuickButton.fromJson(Map<String, dynamic> j) =>
      QuickButton(j['label'] as String, j['amount'] as int, j['type'] as String? ?? 'credit');

  Map<String, dynamic> toJson() => {'label': label, 'amount': amount, 'type': type};

  static List<QuickButton> parse(String json) => [
        for (final b in (jsonDecode(json) as List).cast<Map<String, dynamic>>()) QuickButton.fromJson(b),
      ];
}

class OpDone {
  const OpDone({
    required this.txId,
    required this.type,
    required this.amount,
    required this.player,
    required this.balance,
    required this.queued,
    this.toPlayer,
  });

  final String txId;
  final String type;
  final int amount;
  final Player player;
  final Player? toPlayer;
  final int balance;
  final bool queued;
}

class Standing {
  const Standing(this.place, this.player, this.balance, this.net);

  final int place;
  final Player player;
  final int balance;
  final int net;
}

/// The terminal. Every operation is applied to the local copy first (instant result,
/// works offline), queued, and sent to the server by [SyncService].
class Bank {
  Bank({required this.db, required this.api, required this.sync, required this.spaceId, required this.deviceId});

  final AppDb db;
  final Api api;
  final SyncService sync;
  final String spaceId;
  final String deviceId;

  DateTime Function() clock = DateTime.now;

  String get bankWallet => systemWalletId(spaceId, 'bank');

  Future<SpaceInfo> space() async {
    final raw = await db.getMeta(SyncService.spaceKey(spaceId));
    return SpaceInfo(raw == null ? {'id': spaceId, 'name': '', 'type': 'family'} : jsonDecode(raw) as Map<String, dynamic>);
  }

  // --- who is it ---------------------------------------------------------------------

  Future<LocalCard?> _findCard(CardTap tap) async {
    LocalCard? card;
    if (tap.token != null) card = await db.cardByToken(tap.token!);
    if (card == null && tap.uid != null) card = await db.cardByUid(tap.uid!);
    return card;
  }

  /// Resolve a tap to a player. Unknown cards are looked up online (a card linked on
  /// another phone a minute ago) before giving up.
  Future<Holder> identify(CardTap tap, {String? sessionId}) async {
    var card = await _findCard(tap);
    if (card == null) {
      try {
        await api.post('/cards/resolve', {
          'space_id': spaceId,
          if (tap.token != null) 'token': tap.token,
          if (tap.uid != null) 'uid': tap.uid,
        });
        await sync.sync();
        card = await _findCard(tap);
      } on OfflineError {
        throw ApiError('card_not_found');
      }
    }
    if (card == null) throw ApiError('card_not_found');
    if (card.status == 'blocked') throw ApiError('card_blocked');
    if (card.status != 'active' || card.playerId == null) throw ApiError('card_unlinked');
    final player = await db.playerById(card.playerId!);
    if (player == null || player.deleted || player.spaceId != spaceId) throw ApiError('card_not_found');
    return holderFor(player, sessionId: sessionId, card: card);
  }

  Future<Holder> holderFor(Player player, {String? sessionId, LocalCard? card}) async {
    var walletId = persistentWalletId(player.id);
    if (sessionId != null) {
      final participant = await db.participant(sessionId, player.id);
      if (participant == null) {
        throw ApiError('card_not_in_session', details: {'player': player.name});
      }
      walletId = participant.walletId;
    }
    return Holder(player: player, card: card, walletId: walletId, balance: await db.balanceOf(walletId));
  }

  Map<String, dynamic> _who(Holder h, [String prefix = '']) => h.card != null
      ? {'${prefix}card_token': h.card!.token}
      : {'${prefix}player_id': h.player.id};

  // --- money -------------------------------------------------------------------------

  Future<OpDone> operate({
    required String type, // credit | debit | transfer
    required int amount,
    required Holder subject,
    Holder? receiver,
    String? sessionId,
    String? comment,
  }) async {
    if (amount <= 0) throw ApiError('invalid_amount');
    if (sessionId != null) {
      final session = await db.sessionById(sessionId);
      if (session == null || session.status != 'active') throw ApiError('session_not_active');
    }
    if (type == 'transfer' && (receiver == null || receiver.player.id == subject.player.id)) {
      throw ApiError('same_player');
    }
    final (from, to) = switch (type) {
      'credit' => (bankWallet, subject.walletId),
      'debit' => (subject.walletId, bankWallet),
      _ => (subject.walletId, receiver!.walletId),
    };

    if (from != bankWallet) {
      final info = await space();
      final balance = await db.balanceOf(from);
      if (balance < amount && !info.allowNegative) {
        throw ApiError('insufficient_funds', details: {'balance': balance, 'amount': amount});
      }
      // Several terminals, no network: they cannot see each other's spending.
      final limit = info.offlineSpendLimit;
      if (limit != null && !sync.online && sessionId == null) {
        final spent = await db.pendingOut(from);
        if (spent + amount > limit) {
          throw ApiError('offline_limit', details: {'limit': limit, 'remaining': limit - spent});
        }
      }
    }

    final txId = newId();
    final now = clock().toUtc();
    final payload = {
      'kind': 'transaction',
      'transaction': {
        'id': txId,
        'type': type,
        'space_id': spaceId,
        'session_id': ?sessionId,
        ..._who(subject),
        if (receiver != null) ..._who(receiver, 'to_'),
        'amount': amount,
        'comment': ?comment,
        'device_id': deviceId,
        'created_at': now.toIso8601String(),
      },
    };
    await db.transaction(() async {
      await db.into(db.txs).insert(TxsCompanion.insert(
            id: txId,
            spaceId: spaceId,
            type: type,
            fromWallet: from,
            toWallet: to,
            amount: amount,
            sessionId: Value(sessionId),
            comment: Value(comment),
            createdAt: now,
            pending: const Value(true),
          ));
      await _enqueue('transaction', payload, txId: txId);
    });
    sync.kick();
    return OpDone(
      txId: txId,
      type: type,
      amount: amount,
      player: subject.player,
      toPlayer: receiver?.player,
      balance: await db.balanceOf(subject.walletId),
      queued: !sync.online,
    );
  }

  Future<void> _enqueue(String kind, Map<String, dynamic> op, {String? txId}) =>
      db.into(db.outbox).insert(OutboxCompanion.insert(
            spaceId: spaceId,
            kind: kind,
            payload: jsonEncode(op),
            txId: Value(txId),
            createdAt: clock().toUtc(),
          ));

  Future<OutboxItem?> _queuedTx(String txId) => (db.select(db.outbox)
        ..where((o) => o.txId.equals(txId) & o.state.equals('pending') & o.kind.equals('transaction')))
      .getSingleOrNull();

  /// Add a comment after the fact ("Покупка улицы").
  Future<void> setComment(String txId, String comment) async {
    await sync.idle();
    final queued = await _queuedTx(txId);
    await (db.update(db.txs)..where((t) => t.id.equals(txId))).write(TxsCompanion(comment: Value(comment)));
    if (queued != null) {
      final op = jsonDecode(queued.payload) as Map<String, dynamic>;
      (op['transaction'] as Map<String, dynamic>)['comment'] = comment;
      await (db.update(db.outbox)..where((o) => o.seq.equals(queued.seq)))
          .write(OutboxCompanion(payload: Value(jsonEncode(op))));
    } else {
      try {
        await api.post('/transactions/$txId/comment', {'comment': comment});
      } on Exception {
        // A comment is not worth failing over.
      }
    }
  }

  /// Cancel an operation: drop it if it has not left the phone, otherwise post a reversal.
  Future<void> undo(String txId) async {
    await sync.idle();
    final queued = await _queuedTx(txId);
    if (queued != null) {
      await db.transaction(() async {
        await (db.delete(db.outbox)..where((o) => o.seq.equals(queued.seq))).go();
        await (db.delete(db.txs)..where((t) => t.id.equals(txId))).go();
      });
      return;
    }
    final original = await (db.select(db.txs)..where((t) => t.id.equals(txId))).getSingleOrNull();
    if (original == null) throw ApiError('transaction_not_found');
    final reversed = await (db.select(db.txs)..where((t) => t.reversesId.equals(txId))).getSingleOrNull();
    if (reversed != null) throw ApiError('already_reversed');
    final id = newId();
    final now = clock().toUtc();
    await db.transaction(() async {
      await db.into(db.txs).insert(TxsCompanion.insert(
            id: id,
            spaceId: spaceId,
            type: 'reversal',
            fromWallet: original.toWallet,
            toWallet: original.fromWallet,
            amount: original.amount,
            sessionId: Value(original.sessionId),
            reversesId: Value(txId),
            createdAt: now,
            pending: const Value(true),
          ));
      await _enqueue('transaction', {
        'kind': 'transaction',
        'transaction': {
          'id': id,
          'type': 'reversal',
          'space_id': spaceId,
          'reverses_id': txId,
          'device_id': deviceId,
          'created_at': now.toIso8601String(),
        },
      }, txId: id);
    });
    sync.kick();
  }

  // --- games -------------------------------------------------------------------------

  Future<String> createSession({
    required String name,
    required String moneyMode,
    required int startingCapital,
    List<QuickButton> quickButtons = const [],
    String? templateId,
  }) async {
    final id = newId();
    final now = clock().toUtc();
    final capital = moneyMode == 'reset' ? startingCapital : 0;
    await db.transaction(() async {
      await db.into(db.gameSessions).insert(GameSessionsCompanion.insert(
            id: id,
            spaceId: spaceId,
            name: name,
            moneyMode: moneyMode,
            startingCapital: capital,
            quickButtons: Value(jsonEncode([for (final b in quickButtons) b.toJson()])),
            status: 'lobby',
            deviceId: Value(deviceId),
            createdAt: now,
          ));
      await _enqueue('session.create', {
        'kind': 'session.create',
        'session': {
          'id': id,
          'name': name,
          'money_mode': moneyMode,
          'starting_capital': capital,
          'template_id': ?templateId,
          'quick_buttons': [for (final b in quickButtons) b.toJson()],
          'device_id': deviceId,
          'created_at': now.toIso8601String(),
        },
      });
    });
    sync.kick();
    return id;
  }

  /// Add a player to the game; in a reset game they get the starting capital.
  /// Returns false if the player was already in the game.
  Future<bool> join(String sessionId, Holder holder) async {
    final session = await db.sessionById(sessionId);
    if (session == null) throw ApiError('session_not_found');
    if (session.status == 'finished') throw ApiError('session_finished');
    if (await db.participant(sessionId, holder.player.id) != null) return false;
    final playerId = holder.player.id;
    final reset = session.moneyMode == 'reset';
    final walletId = reset ? sessionWalletId(sessionId, playerId) : persistentWalletId(playerId);
    final txId = newId();
    final now = clock().toUtc();
    await db.transaction(() async {
      if (reset) {
        await db.into(db.wallets).insertOnConflictUpdate(WalletsCompanion.insert(
              id: walletId,
              spaceId: spaceId,
              kind: 'session',
              playerId: Value(playerId),
              sessionId: Value(sessionId),
            ));
      }
      await db.into(db.participants).insert(ParticipantsCompanion.insert(
            sessionId: sessionId,
            playerId: playerId,
            walletId: walletId,
            joinedAt: now,
          ));
      final capital = reset ? session.startingCapital : 0;
      if (capital > 0) {
        await db.into(db.txs).insert(TxsCompanion.insert(
              id: txId,
              spaceId: spaceId,
              type: 'session_start',
              fromWallet: bankWallet,
              toWallet: walletId,
              amount: capital,
              sessionId: Value(sessionId),
              comment: Value(session.name),
              createdAt: now,
              pending: const Value(true),
            ));
      }
      await _enqueue(
        'session.join',
        {
          'kind': 'session.join',
          'session_id': sessionId,
          'join': {
            'player_id': playerId,
            if (holder.card != null) 'card_token': holder.card!.token,
            'transaction_id': txId,
            'joined_at': now.toIso8601String(),
            'device_id': deviceId,
          },
        },
        txId: capital > 0 ? txId : null,
      );
    });
    sync.kick();
    return true;
  }

  Future<void> setStatus(String sessionId, String status) async {
    final now = clock().toUtc();
    final session = await db.sessionById(sessionId);
    await db.transaction(() async {
      await (db.update(db.gameSessions)..where((s) => s.id.equals(sessionId))).write(GameSessionsCompanion(
            status: Value(status),
            startedAt: session?.startedAt == null && status == 'active' ? Value(now) : const Value.absent(),
          ));
      await _enqueue('session.status', {
        'kind': 'session.status',
        'session_id': sessionId,
        'status': {'status': status, 'at': now.toIso8601String()},
      });
    });
    sync.kick();
  }

  Future<void> finish(String sessionId, {Map<String, int> prizes = const {}}) async {
    final now = clock().toUtc();
    final prizeOps = <Map<String, dynamic>>[];
    await db.transaction(() async {
      for (final entry in prizes.entries) {
        final id = newId();
        prizeOps.add({'player_id': entry.key, 'amount': entry.value, 'transaction_id': id});
        await db.into(db.txs).insert(TxsCompanion.insert(
              id: id,
              spaceId: spaceId,
              type: 'prize',
              fromWallet: bankWallet,
              toWallet: persistentWalletId(entry.key),
              amount: entry.value,
              sessionId: Value(sessionId),
              createdAt: now,
              pending: const Value(true),
            ));
      }
      await (db.update(db.gameSessions)..where((s) => s.id.equals(sessionId)))
          .write(GameSessionsCompanion(status: const Value('finished'), finishedAt: Value(now)));
      await _enqueue('session.finish', {
        'kind': 'session.finish',
        'session_id': sessionId,
        'finish': {'prizes': prizeOps, 'finished_at': now.toIso8601String(), 'device_id': deviceId},
      });
    });
    sync.kick();
  }

  /// Ranking: by balance in a reset game, by the net gain otherwise.
  Future<List<Standing>> standings(String sessionId) async {
    final session = await db.sessionById(sessionId);
    final rows = await (db.select(db.participants)..where((p) => p.sessionId.equals(sessionId))).get();
    final txs = await db.sessionTxs(sessionId);
    final walletIds = {for (final r in rows) r.walletId};
    final net = {for (final w in walletIds) w: 0};
    for (final t in txs) {
      if (t.type == 'session_start' || t.type == 'prize') continue;
      if (net.containsKey(t.fromWallet)) net[t.fromWallet] = net[t.fromWallet]! - t.amount;
      if (net.containsKey(t.toWallet)) net[t.toWallet] = net[t.toWallet]! + t.amount;
    }
    final items = <(Player, int, int)>[];
    for (final r in rows) {
      final player = await db.playerById(r.playerId);
      if (player == null) continue;
      items.add((player, await db.balanceOf(r.walletId), net[r.walletId] ?? 0));
    }
    final byBalance = session?.moneyMode != 'persistent';
    items.sort((a, b) {
      final c = byBalance ? b.$2.compareTo(a.$2) : b.$3.compareTo(a.$3);
      return c != 0 ? c : a.$1.name.compareTo(b.$1.name);
    });
    return [for (var i = 0; i < items.length; i++) Standing(i + 1, items[i].$1, items[i].$2, items[i].$3)];
  }
}
