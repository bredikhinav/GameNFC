import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../../ui/widgets.dart';

final sessionsProvider = StreamProvider<List<GameSession>>((ref) {
  final s = ref.watch(servicesProvider);
  return s.db.watchSessions(ref.watch(spaceProvider).id);
});

String sessionRoute(GameSession s) => switch (s.status) {
      'lobby' => '/game/${s.id}/lobby',
      'finished' => '/game/${s.id}/results',
      _ => '/game/${s.id}/terminal',
    };

class GamesTab extends ConsumerWidget {
  const GamesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider).value ?? const <GameSession>[];
    final open = sessions.where((s) => s.status != 'finished').toList();
    final done = sessions.where((s) => s.status == 'finished').toList();
    Widget tile(GameSession s) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Panel(
            onTap: () => context.push(sessionRoute(s)),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: s.status == 'finished' ? C.surfaceSand : C.coinPale, borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.sports_esports_outlined, color: C.ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.name, style: T.title),
                  Text(
                    '${switch (s.status) {
                      'lobby' => 'Сбор игроков',
                      'active' => 'Идёт',
                      'paused' => 'Пауза',
                      _ => 'Закончена',
                    }} · ${dayTitle(s.createdAt).toLowerCase()}, ${time(s.createdAt)}',
                    style: T.small,
                  ),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: C.text2),
            ]),
          ),
        );
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Игры', style: T.h1),
          const SizedBox(height: 16),
          if (sessions.isEmpty)
            const Note('Здесь появятся ваши игры. Телефон ведущего становится банком: '
                'списания, начисления и итоги — без интернета.'),
          if (open.isNotEmpty) ...[const Text('СЕЙЧАС', style: T.caps), const SizedBox(height: 10), ...open.map(tile)],
          if (done.isNotEmpty) ...[const SizedBox(height: 8), const Text('ЗАКОНЧЕННЫЕ', style: T.caps), const SizedBox(height: 10), ...done.map(tile)],
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Btn('Новая игра', icon: Icons.contactless_outlined, onPressed: () => context.push('/game/new')),
      ),
    ]);
  }
}
