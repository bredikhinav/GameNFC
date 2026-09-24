import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

final membersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final s = ref.watch(servicesProvider);
  final list = await s.api.get('/spaces/${ref.watch(spaceProvider).id}/members') as List;
  return list.cast<Map<String, dynamic>>();
});

/// Other adults who may run the terminal (second parent, camp counsellors).
class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key});

  static const roles = {'owner': 'Владелец', 'admin': 'Админ', 'operator': 'Ведущий'};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider);
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          const ScreenHeader('Взрослые и ведущие'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text(
                'Ведущий может проводить игры и операции, но не меняет правила и профили детей. '
                'Сначала он создаёт аккаунт в приложении, потом вы добавляете его по почте.',
                style: T.secondary,
              ),
              const SizedBox(height: 16),
              ...switch (members) {
                AsyncData(:final value) => [
                    for (final m in value)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Panel(
                          child: Row(children: [
                            Avatar(m['name'] as String? ?? m['email'] as String, size: 40),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text((m['name'] as String?)?.isNotEmpty == true ? m['name'] as String : m['email'] as String, style: T.bodyBold),
                                Text(m['email'] as String, style: T.small),
                              ]),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: C.greenPale, borderRadius: BorderRadius.circular(20)),
                              child: Text(roles[m['role']] ?? '', style: T.small.copyWith(color: C.greenDark, fontWeight: FontWeight.w700)),
                            ),
                          ]),
                        ),
                      ),
                  ],
                AsyncError() => [const Note('Список доступен только онлайн.')],
                _ => [const Center(child: CircularProgressIndicator())],
              },
              const SizedBox(height: 8),
              DashedBox(onTap: () => _invite(context, ref), child: const Text('+ Пригласить', style: T.bodyBold)),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    final email = TextEditingController();
    var role = 'operator';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Пригласить взрослого', style: T.h2),
            const SizedBox(height: 16),
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(hintText: 'Почта его аккаунта')),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'operator', label: Text('Ведущий')),
                ButtonSegment(value: 'admin', label: Text('Админ')),
              ],
              selected: {role},
              onSelectionChanged: (v) => setState(() => role = v.first),
            ),
            const SizedBox(height: 16),
            Btn('Добавить', onPressed: () async {
              try {
                await ref.read(servicesProvider).api.post('/spaces/${ref.read(spaceProvider).id}/members', {'email': email.text.trim(), 'role': role});
                ref.invalidate(membersProvider);
                if (context.mounted) Navigator.pop(context);
              } on Exception catch (e) {
                if (context.mounted) toast(context, describe(e));
              }
            }),
          ]),
        ),
      ),
    );
  }
}
