import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../core/ids.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../../ui/widgets.dart';
import 'games_tab.dart';
import 'history_tab.dart';
import 'settings_tab.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = [const FamilyTab(), const GamesTab(), const HistoryTab(), const SettingsTab()];
    return Scaffold(
      body: SafeArea(bottom: false, child: IndexedStack(index: _tab, children: tabs)),
      bottomNavigationBar: NavigationBar(
        backgroundColor: C.bg,
        indicatorColor: C.greenPale,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.people_outline_rounded), label: 'Семья'),
          NavigationDestination(icon: Icon(Icons.sports_esports_outlined), label: 'Игры'),
          NavigationDestination(icon: Icon(Icons.schedule_rounded), label: 'История'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Настройки'),
        ],
      ),
    );
  }
}

class FamilyTab extends ConsumerWidget {
  const FamilyTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(spaceProvider);
    final players = ref.watch(playersProvider).value ?? const <Player>[];
    final balances = ref.watch(balancesProvider).value ?? const <String, int>{};
    final sync = ref.read(servicesProvider).sync;

    return Column(children: [
      Expanded(
        child: RefreshIndicator(
          color: C.green,
          onRefresh: () => sync.sync(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Row(children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(space.name, style: T.h1, maxLines: 1),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: C.surface,
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(color: C.border),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Coin(size: 18),
                    const SizedBox(width: 8),
                    Text('Валюта: ${space.currencyName}', style: T.label),
                  ]),
                ),
              ]),
              const SizedBox(height: 18),
              const _PendingRequests(),
              for (final p in players) ...[
                _PlayerTile(player: p, balance: balances[persistentWalletId(p.id)] ?? 0),
                const SizedBox(height: 12),
              ],
              if (space.isAdmin)
                DashedBox(
                  onTap: () => _addChild(context, ref),
                  child: Row(mainAxisSize: MainAxisSize.min, children: const [
                    Icon(Icons.add_rounded, color: C.ink),
                    SizedBox(width: 8),
                    Text('Добавить ребёнка', style: T.bodyBold),
                  ]),
                ),
              const SizedBox(height: 16),
              const _RulesCard(),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Btn('Новая игра', icon: Icons.contactless_outlined, onPressed: () => context.push('/game/new')),
      ),
    ]);
  }

  Future<void> _addChild(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    var consent = false;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Новый игрок', style: T.h2),
            const SizedBox(height: 8),
            const Text('Только имя или прозвище: ни фото, ни телефона, ни почты ребёнка не нужно.', style: T.secondary),
            const SizedBox(height: 16),
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              maxLength: 40,
              decoration: const InputDecoration(hintText: 'Имя или прозвище', counterText: ''),
            ),
            CheckboxListTile(
              value: consent,
              onChanged: (v) => setState(() => consent = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Я законный представитель ребёнка и согласен на обработку его данных (имя/прозвище)',
                style: T.secondary,
              ),
            ),
            const SizedBox(height: 8),
            Btn('Добавить', onPressed: () async {
              if (name.text.trim().isEmpty || !consent) return;
              try {
                final s = ref.read(servicesProvider);
                await s.api.post('/spaces/${ref.read(spaceProvider).id}/players', {'name': name.text.trim(), 'consent': true});
                await s.sync.sync();
                if (context.mounted) Navigator.pop(context, true);
              } on Exception catch (e) {
                if (context.mounted) toast(context, describe(e));
              }
            }),
          ]),
        ),
      ),
    );
    if (created == true && context.mounted) toast(context, 'Игрок добавлен. Теперь привяжите карту');
  }
}

class _PlayerTile extends ConsumerWidget {
  const _PlayerTile({required this.player, required this.balance});

  final Player player;
  final int balance;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(servicesProvider).db;
    return StreamBuilder<List<LocalCard>>(
      stream: db.watchCards(player.id),
      builder: (context, snap) {
        final cards = (snap.data ?? const []).where((c) => c.status == 'active').length;
        final phone = player.linkedDevices > 0 ? ' · телефон привязан' : '';
        return Panel(
          onTap: () => context.push('/player/${player.id}'),
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            PlayerAvatar(player, size: 54),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(player.name, style: T.title),
                const SizedBox(height: 4),
                if (cards == 0)
                  GestureDetector(
                    onTap: () => context.push('/player/${player.id}/card'),
                    child: Text('Нет карты — привязать',
                        style: T.small.copyWith(color: C.green, fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline, decorationColor: C.green)),
                  )
                else
                  Text('$cards ${plural(cards, 'карта', 'карты', 'карт')}$phone', style: T.small),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money(balance), style: T.amountM.copyWith(fontSize: 22)),
              Text(plural(balance, 'монета', 'монеты', 'монет'), style: T.small),
            ]),
          ]),
        );
      },
    );
  }
}

class _RulesCard extends ConsumerWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(spaceProvider);
    final allowances = ref.watch(allowancesProvider).value ?? const [];
    final weekdays = ['понедельникам', 'вторникам', 'средам', 'четвергам', 'пятницам', 'субботам', 'воскресеньям'];
    return Panel(
      color: C.surfaceSand,
      border: false,
      onTap: space.isAdmin ? () => context.push('/rules') : null,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Регулярные начисления', style: T.title),
        const SizedBox(height: 10),
        if (allowances.isEmpty)
          const Text('Нет. Например, «карманные» каждое воскресенье', style: T.secondary),
        for (final a in allowances)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text('${a['comment']}, по ${weekdays[a['weekday'] as int]}', style: T.secondary)),
              Text('+${a['amount']}', style: T.bodyBold.copyWith(color: C.green)),
            ]),
          ),
        if (space.dailyTransferLimit != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              const Expanded(child: Text('Лимит перевода в день', style: T.secondary)),
              Text('${space.dailyTransferLimit}', style: T.bodyBold),
            ]),
          ),
      ]),
    );
  }
}

final allowancesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final s = ref.watch(servicesProvider);
  final space = ref.watch(spaceProvider);
  try {
    final list = await s.api.get('/spaces/${space.id}/allowances') as List;
    return list.cast<Map<String, dynamic>>();
  } on Exception {
    return const [];
  }
});

final pendingRequestsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final s = ref.watch(servicesProvider);
  final space = ref.watch(spaceProvider);
  if (!space.isAdmin) return const [];
  try {
    final list = await s.api.get('/spaces/${space.id}/transfer-requests') as List;
    return list.cast<Map<String, dynamic>>();
  } on Exception {
    return const [];
  }
});

class _PendingRequests extends ConsumerWidget {
  const _PendingRequests();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(pendingRequestsProvider).value ?? const [];
    final players = {for (final p in ref.watch(playersProvider).value ?? const <Player>[]) p.id: p.name};
    if (requests.isEmpty) return const SizedBox.shrink();
    final api = ref.read(servicesProvider).api;
    final spaceId = ref.read(spaceProvider).id;
    Future<void> decide(String id, bool approve) async {
      try {
        await api.post('/spaces/$spaceId/transfer-requests/$id/${approve ? 'approve' : 'reject'}');
        await ref.read(servicesProvider).sync.sync();
      } on Exception catch (e) {
        if (context.mounted) toast(context, describe(e));
      }
      ref.invalidate(pendingRequestsProvider);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Panel(
        color: C.coinPale,
        border: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Ждут вашего решения', style: T.title),
          for (final r in requests)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '${players[r['from_player_id']] ?? '?'} → ${players[r['to_player_id']] ?? '?'}: ${r['amount']}',
                    style: T.body,
                  ),
                ),
                IconButton(icon: const Icon(Icons.close_rounded, color: C.red), onPressed: () => decide(r['id'] as String, false)),
                IconButton(icon: const Icon(Icons.check_rounded, color: C.green), onPressed: () => decide(r['id'] as String, true)),
              ]),
            ),
        ]),
      ),
    );
  }
}
