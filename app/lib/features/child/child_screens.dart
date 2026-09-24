import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/ids.dart';
import '../../core/storage.dart';
import '../../core/theme.dart';
import '../../nfc/card_reader.dart';
import '../../ui/widgets.dart';
import '../family/player_screen.dart' show GoalCard;

/// Child mode shows the last known data offline; only the Bank phone makes operations.
class ChildData {
  const ChildData(this.me, this.fetchedAt, {this.stale = false});

  final Map<String, dynamic> me;
  final DateTime fetchedAt;
  final bool stale;

  Map<String, dynamic> get player => me['player'] as Map<String, dynamic>;
  int get balance => me['balance'] as int;
  Map<String, dynamic>? get goal => me['goal'] as Map<String, dynamic>?;
  Map<String, dynamic>? get game => me['active_game'] as Map<String, dynamic>?;
  List<Map<String, dynamic>> get peers => (me['peers'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get recent => (me['recent'] as List).cast<Map<String, dynamic>>();
  int get transferredToday => me['transferred_today'] as int? ?? 0;
  int? get dailyLimit => me['daily_transfer_limit'] as int?;
  int? get threshold => me['transfer_approval_threshold'] as int?;
  String get currency => (me['space'] as Map)['currency_name'] as String? ?? 'монеты';
}

class ChildController extends AsyncNotifier<ChildData> {
  Services get _s => ref.read(servicesProvider);

  @override
  Future<ChildData> build() async {
    final cached = await _s.store.read(Keys.childCache);
    if (cached != null) {
      final j = jsonDecode(cached) as Map<String, dynamic>;
      Future.microtask(refresh);
      return ChildData(j['me'] as Map<String, dynamic>, DateTime.parse(j['at'] as String), stale: true);
    }
    return _fetch();
  }

  Future<ChildData> _fetch() async {
    final me = await _s.api.get('/me') as Map<String, dynamic>;
    final now = DateTime.now();
    await _s.store.write(Keys.childCache, jsonEncode({'me': me, 'at': now.toIso8601String()}));
    return ChildData(me, now);
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(await _fetch());
    } on OfflineError {
      final current = state.value;
      if (current != null) state = AsyncData(ChildData(current.me, current.fetchedAt, stale: true));
    } on ApiError catch (e) {
      if (e.status == 401) await ref.read(authProvider.notifier).logout();
    }
  }
}

final childProvider = AsyncNotifierProvider<ChildController, ChildData>(ChildController.new);

class ChildHomeScreen extends ConsumerWidget {
  const ChildHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(childProvider);
    return Scaffold(
      body: SafeArea(
        child: switch (data) {
          AsyncData(:final value) => RefreshIndicator(
              color: C.green,
              onRefresh: () => ref.read(childProvider.notifier).refresh(),
              child: _Home(data: value),
            ),
          AsyncError(:final error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(describe(error), textAlign: TextAlign.center, style: T.body),
                  const SizedBox(height: 16),
                  Btn('Повторить', onPressed: () => ref.invalidate(childProvider)),
                ]),
              ),
            ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Home extends ConsumerWidget {
  const _Home({required this.data});

  final ChildData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = data.player['name'] as String;
    final game = data.game;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
      Row(children: [
        Avatar(name, size: 44, seed: data.player['id'] as String),
        const SizedBox(width: 12),
        Expanded(child: Text('Привет, $name!', style: T.h2)),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz_rounded),
          onSelected: (_) async {
            if (await confirm(context, 'Отключить телефон?', 'Чтобы подключить снова, понадобится новый QR-код от родителя.', danger: true)) {
              try {
                await ref.read(servicesProvider).api.post('/me/logout');
              } on Exception {
                // Unlink locally anyway.
              }
              await ref.read(authProvider.notifier).logout();
            }
          },
          itemBuilder: (_) => const [PopupMenuItem(value: 'logout', child: Text('Отключить этот телефон'))],
        ),
      ]),
      const SizedBox(height: 18),
      GoalCard(
        title: 'Моя копилка',
        balance: data.balance,
        goalTitle: data.goal?['title'] as String?,
        goalTarget: data.goal?['target_amount'] as int?,
      ),
      if (game != null) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: C.coin, width: 2),
          ),
          child: Row(children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: C.coinPale, borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.sports_esports_outlined, color: C.ink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Сейчас идёт игра', style: T.small),
                Text(game['name'] as String, style: T.title),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money(game['balance'] as int), style: T.amountM),
              Text('${game['place']}-е место', style: T.small),
            ]),
          ]),
        ),
      ],
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: Btn('Перевести', kind: BtnKind.dark, icon: Icons.swap_horiz_rounded, onPressed: () => context.push('/child/transfer'))),
        const SizedBox(width: 12),
        Expanded(child: Btn('История', kind: BtnKind.outline, icon: Icons.schedule_rounded, onPressed: () => context.push('/child/history'))),
      ]),
      const SizedBox(height: 22),
      const Text('Последние', style: T.title),
      const SizedBox(height: 6),
      for (final item in data.recent) HistoryRow(item: item),
      if (data.recent.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Пока пусто', style: T.secondary)),
      const SizedBox(height: 24),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(data.stale ? Icons.cloud_off_rounded : Icons.refresh_rounded, size: 16, color: C.text2),
        const SizedBox(width: 6),
        Text('Обновлено ${agoText(data.fetchedAt)}', style: T.small),
      ]),
    ]);
  }
}

String historyTitle(Map<String, dynamic> item) {
  final who = (item['counterparty'] as Map?)?['name'] as String?;
  final comment = item['comment'] as String?;
  return switch (item['type']) {
    'transfer' => item['direction'] == 'out' ? 'Перевод ${who == null ? '' : dative(who)}' : 'Перевод от ${who == null ? '' : genitive(who)}',
    'prize' => 'Приз за победу',
    'session_start' => 'Старт игры',
    'reversal' => 'Отмена операции',
    'allowance' => comment ?? 'Карманные монеты',
    _ => comment ?? (item['direction'] == 'in' ? 'Начисление' : 'Оплата'),
  };
}

class HistoryRow extends StatelessWidget {
  const HistoryRow({super.key, required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final incoming = item['direction'] == 'in';
    final at = DateTime.parse(item['created_at'] as String);
    final where = item['session_id'] == null ? 'Копилка' : 'Игра';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: item['type'] == 'prize' ? C.coinPale : (incoming ? C.greenPale : C.redPale),
            shape: BoxShape.circle,
          ),
          child: Icon(
            item['type'] == 'prize' ? Icons.emoji_events_outlined : (incoming ? Icons.south_west_rounded : Icons.north_east_rounded),
            size: 18,
            color: item['type'] == 'prize' ? C.ink : (incoming ? C.green : C.red),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(historyTitle(item), style: T.bodyBold),
            Text('$where · ${dayTitle(at) == 'СЕГОДНЯ' ? 'сегодня' : dayTitle(at).toLowerCase()}, ${time(at)}', style: T.small),
          ]),
        ),
        Text(signed(item['signed_amount'] as int), style: T.bodyBold.copyWith(color: incoming ? C.green : C.red, fontSize: 16)),
      ]),
    );
  }
}

class ChildTransferScreen extends ConsumerStatefulWidget {
  const ChildTransferScreen({super.key});

  @override
  ConsumerState<ChildTransferScreen> createState() => _ChildTransferScreenState();
}

class _ChildTransferScreenState extends ConsumerState<ChildTransferScreen> {
  Map<String, dynamic>? _to;
  String? _cardToken;
  int _amount = 0;
  bool _busy = false;

  Future<void> _byCard() async {
    try {
      final tap = await ref.read(servicesProvider).reader.read(prompt: 'Приложите карту друга');
      if (tap.token == null) {
        if (mounted) toast(context, 'Карта не распознана');
        return;
      }
      setState(() {
        _cardToken = tap.token;
        _to = {'name': 'по карте'};
      });
    } on NfcCancelled {
      return;
    } on NfcUnavailable {
      if (mounted) toast(context, 'На этом телефоне нет NFC');
    }
  }

  Future<void> _send(ChildData data) async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(servicesProvider).api.post('/me/transfers', {
        'id': newId(),
        if (_cardToken != null) 'to_card_token': _cardToken else 'to_player_id': _to!['id'],
        'amount': _amount,
      }) as Map<String, dynamic>;
      await ref.read(childProvider.notifier).refresh();
      if (!mounted) return;
      toast(context, res['status'] == 'pending_approval' ? 'Перевод ждёт подтверждения родителя' : 'Готово!');
      Navigator.pop(context);
    } on Exception catch (e) {
      if (mounted) toast(context, describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(childProvider).value;
    if (data == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final limit = data.dailyLimit;
    final left = limit == null ? null : (limit - data.transferredToday).clamp(0, limit);
    final toName = _to?['name'] as String?;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const ScreenHeader('Перевод'),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 20), children: [
              const Text('Кому', style: T.label),
              const SizedBox(height: 10),
              SizedBox(
                height: 112,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final p in data.peers)
                    _PeerTile(
                      name: p['name'] as String,
                      seed: p['id'] as String,
                      selected: _to?['id'] == p['id'],
                      onTap: () => setState(() {
                        _to = p;
                        _cardToken = null;
                      }),
                    ),
                  _PeerTile(name: 'По карте', icon: Icons.contactless_outlined, selected: _cardToken != null, onTap: _byCard),
                ]),
              ),
              const SizedBox(height: 16),
              Panel(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  const Text('Сколько монет', style: T.secondary),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(money(_amount), style: T.amountXL),
                    const SizedBox(width: 12),
                    const Coin(size: 30),
                  ]),
                  const SizedBox(height: 14),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (final v in [10, 20, 50])
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: PillButton('$v', selected: _amount == v, onPressed: () => setState(() => _amount = v)),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: PillButton('Другое', onPressed: () async {
                        final c = TextEditingController();
                        final ok = await confirmNumber(context, c);
                        if (ok) setState(() => _amount = int.tryParse(c.text) ?? 0);
                      }),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: C.surfaceSand, borderRadius: BorderRadius.circular(18)),
                child: Column(children: [
                  _infoRow('Из копилки', '${money(data.balance)} → ${money(data.balance - _amount)}'),
                  if (limit != null) _infoRow('Можно ещё сегодня', '${money(left!)} из ${money(limit)}'),
                  if (data.threshold != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Переводы больше ${data.threshold} монет подтверждает родитель.', style: T.secondary),
                    ),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Btn(
              toName == null || _amount == 0
                  ? 'Выберите, кому и сколько'
                  : 'Перевести ${money(_amount)} ${_cardToken != null ? 'по карте' : dative(toName)}',
              kind: BtnKind.dark,
              busy: _busy,
              onPressed: toName == null || _amount <= 0 || _amount > data.balance ? null : () => _send(data),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Expanded(child: Text(label, style: T.secondary)), Text(value, style: T.bodyBold)]),
      );
}

Future<bool> confirmNumber(BuildContext context, TextEditingController c) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: C.bg,
        title: const Text('Сколько монет', style: T.h3),
        content: TextField(controller: c, autofocus: true, keyboardType: TextInputType.number),
        actions: [TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Готово'))],
      ),
    ) ??
    false;

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.name, required this.selected, required this.onTap, this.seed, this.icon});

  final String name;
  final String? seed;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Material(
          color: C.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: selected ? C.green : C.border, width: selected ? 2 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: SizedBox(
              width: 92,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null)
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(color: C.surfaceSand, shape: BoxShape.circle),
                    child: Icon(icon, color: C.ink),
                  )
                else
                  Avatar(name, size: 52, seed: seed),
                const SizedBox(height: 8),
                Text(name, style: T.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ),
        ),
      );
}

final childHistoryProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final list = await ref.read(servicesProvider).api.get('/me/history', query: {'limit': 100}) as List;
  return list.cast<Map<String, dynamic>>();
});

class ChildHistoryScreen extends ConsumerStatefulWidget {
  const ChildHistoryScreen({super.key});

  @override
  ConsumerState<ChildHistoryScreen> createState() => _ChildHistoryScreenState();
}

class _ChildHistoryScreenState extends ConsumerState<ChildHistoryScreen> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(childHistoryProvider);
    final cached = ref.watch(childProvider).value?.recent ?? const [];
    final items = (history.value ?? cached).where((i) => switch (_filter) {
          'piggy' => i['session_id'] == null,
          'games' => i['session_id'] != null,
          _ => true,
        });
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final i in items) {
      groups.putIfAbsent(dayTitle(DateTime.parse(i['created_at'] as String)), () => []).add(i);
    }
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          const ScreenHeader('История'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                PillButton('Все', selected: _filter == 'all', onPressed: () => setState(() => _filter = 'all')),
                const SizedBox(width: 8),
                PillButton('Копилка', selected: _filter == 'piggy', onPressed: () => setState(() => _filter = 'piggy')),
                const SizedBox(width: 8),
                PillButton('Игры', selected: _filter == 'games', onPressed: () => setState(() => _filter = 'games')),
              ]),
              const SizedBox(height: 18),
              if (history is AsyncError) const Padding(padding: EdgeInsets.only(bottom: 12), child: OfflinePill(text: 'Нет сети · показаны последние')),
              for (final g in groups.entries) ...[
                Text(g.key, style: T.caps),
                const SizedBox(height: 8),
                Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: Column(children: [
                    for (var i = 0; i < g.value.length; i++) ...[if (i > 0) const Divider(), HistoryRow(item: g.value[i])],
                  ]),
                ),
                const SizedBox(height: 16),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
