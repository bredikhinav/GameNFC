import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/theme.dart';
import '../../ui/widgets.dart';

/// Password reset: request a code by email, then set a new password with it.
class ForgotScreen extends ConsumerStatefulWidget {
  const ForgotScreen({super.key});

  @override
  ConsumerState<ForgotScreen> createState() => _ForgotScreenState();
}

class _ForgotScreenState extends ConsumerState<ForgotScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Exception catch (e) {
      if (mounted) toast(context, describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(servicesProvider).api;
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const ScreenHeader('Новый пароль'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!_sent) ...[
                const Text('Пришлём код на почту, указанную при регистрации.', style: T.secondary),
                const SizedBox(height: 16),
                TextField(controller: _email, keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(hintText: 'name@mail.ru')),
                const SizedBox(height: 16),
                Btn('Получить код', busy: _busy, onPressed: () => _run(() async {
                  await api.post('/auth/password/forgot', {'email': _email.text.trim()});
                  setState(() => _sent = true);
                })),
              ] else ...[
                const Text('Введите код из письма и новый пароль.', style: T.secondary),
                const SizedBox(height: 16),
                TextField(controller: _code, decoration: const InputDecoration(hintText: 'Код из письма')),
                const SizedBox(height: 12),
                TextField(controller: _password, obscureText: true,
                    decoration: const InputDecoration(hintText: 'Новый пароль, минимум 8 символов')),
                const SizedBox(height: 16),
                Btn('Сохранить пароль', busy: _busy, onPressed: () => _run(() async {
                  await api.post('/auth/password/reset', {'token': _code.text.trim(), 'password': _password.text});
                  if (!context.mounted) return;
                  toast(context, 'Пароль изменён, войдите заново');
                  Navigator.pop(context);
                })),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
