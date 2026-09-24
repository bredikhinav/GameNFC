import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/api.dart';
import 'core/errors.dart';
import 'core/pin.dart';
import 'core/storage.dart';
import 'data/bank.dart';
import 'data/db.dart';
import 'data/sync.dart';
import 'nfc/card_reader.dart';

/// Long-lived objects created in main() and injected with a ProviderScope override.
class Services {
  Services({
    required this.store,
    required this.db,
    required this.api,
    required this.sync,
    required this.reader,
    required this.deviceId,
    required this.navigatorKey,
  });

  final KeyValueStore store;
  final AppDb db;
  final Api api;
  final SyncService sync;
  final CardReader reader;
  final String deviceId;
  final GlobalKey<NavigatorState> navigatorKey;
}

final servicesProvider = Provider<Services>((ref) => throw UnimplementedError('override in main'));

sealed class AuthState {
  const AuthState();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class LoggedOut extends AuthState {
  const LoggedOut();
}

class AdultSession extends AuthState {
  const AdultSession({required this.user, required this.space, required this.spaces, this.pin});

  final Map<String, dynamic> user;
  final SpaceInfo space;
  final List<SpaceInfo> spaces;
  final PinHash? pin;

  String get email => user['email'] as String;
}

class ChildSession extends AuthState {
  const ChildSession({required this.playerName});

  final String playerName;
}

class AuthController extends Notifier<AuthState> {
  Services get _s => ref.read(servicesProvider);

  @override
  AuthState build() {
    _s.api.onLoggedOut = () {
      // Session expired: keep the local data and the unsent queue for the next login.
      if (state is AdultSession) logout(wipe: false);
    };
    Future.microtask(restore);
    return const AuthLoading();
  }

  Future<void> restore() async {
    final store = _s.store;
    final childToken = await store.read(Keys.childToken);
    if (childToken != null) {
      state = ChildSession(playerName: await store.read('child_name') ?? '');
      return;
    }
    if (await store.read(Keys.accessToken) == null) {
      state = const LoggedOut();
      return;
    }
    await _loadAdult();
  }

  Future<void> _loadAdult() async {
    final store = _s.store;
    Map<String, dynamic>? user;
    List<dynamic>? spaces;
    try {
      user = await _s.api.get('/auth/me') as Map<String, dynamic>;
      spaces = await _s.api.get('/spaces') as List<dynamic>;
      if (spaces.isEmpty) {
        spaces = [await _s.api.post('/spaces', {'name': 'Моя семья', 'type': 'family'})];
      }
      await store.write('user_json', jsonEncode(user));
      await store.write('spaces_json', jsonEncode(spaces));
    } on OfflineError {
      final cachedUser = await store.read('user_json');
      final cachedSpaces = await store.read('spaces_json');
      if (cachedUser == null || cachedSpaces == null) {
        state = const LoggedOut();
        return;
      }
      user = jsonDecode(cachedUser) as Map<String, dynamic>;
      spaces = jsonDecode(cachedSpaces) as List<dynamic>;
    } on ApiError {
      await logout();
      return;
    }
    final all = [for (final s in spaces) SpaceInfo(Map<String, dynamic>.from(s as Map))];
    final savedId = await store.read(Keys.spaceId);
    final space = all.firstWhere((s) => s.id == savedId, orElse: () => all.first);
    await store.write(Keys.spaceId, space.id);
    await _s.db.setMeta(SyncService.spaceKey(space.id), jsonEncode(space.json));

    final pinJson = user['pin'] as Map<String, dynamic>?;
    final pin = pinJson == null ? null : PinHash.fromJson(pinJson);
    await store.write(Keys.pin, pinJson == null ? null : jsonEncode(pinJson));

    _s.sync.configure(spaceId: space.id, deviceId: _s.deviceId, deviceName: 'Телефон ${user['name'] ?? ''}'.trim());
    state = AdultSession(user: user, space: space, spaces: all, pin: pin);
    _s.sync.kick();
  }

  Future<void> login(String email, String password) async {
    final tokens = await _s.api.post('/auth/login', {'email': email, 'password': password});
    await _s.api.saveTokens(tokens as Map<String, dynamic>);
    await _loadAdult();
  }

  Future<void> register(String name, String email, String password) async {
    final tokens = await _s.api.post('/auth/register', {'email': email, 'password': password, 'name': name});
    await _s.api.saveTokens(tokens as Map<String, dynamic>);
    await _loadAdult();
  }

  /// Child's phone: scan the parent's QR code.
  Future<void> claim(String code) async {
    final res = await _s.api.post('/device-link/claim', {'code': code, 'device_name': 'Телефон ребёнка'})
        as Map<String, dynamic>;
    await _s.store.write(Keys.childToken, res['token'] as String);
    final name = (res['player'] as Map)['name'] as String;
    await _s.store.write('child_name', name);
    state = ChildSession(playerName: name);
  }

  Future<void> refreshUser() async {
    if (state is AdultSession) await _loadAdult();
  }

  Future<void> switchSpace(String spaceId) async {
    await _s.store.write(Keys.spaceId, spaceId);
    await _loadAdult();
  }

  Future<void> logout({bool wipe = true}) async {
    final refresh = await _s.store.read(Keys.refreshToken);
    if (refresh != null) {
      try {
        await _s.api.post('/auth/logout', {'refresh_token': refresh});
      } on Exception {
        // Logging out works offline too.
      }
    }
    for (final key in [Keys.accessToken, Keys.refreshToken, Keys.childToken, Keys.spaceId, Keys.pin,
        Keys.childCache, 'user_json', 'spaces_json', 'child_name']) {
      await _s.store.write(key, null);
    }
    if (wipe) await _s.db.wipe();
    state = const LoggedOut();
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

final bankProvider = Provider<Bank>((ref) {
  final s = ref.watch(servicesProvider);
  final auth = ref.watch(authProvider);
  if (auth is! AdultSession) throw StateError('bank needs an adult session');
  return Bank(db: s.db, api: s.api, sync: s.sync, spaceId: auth.space.id, deviceId: s.deviceId);
});

final spaceProvider = Provider<SpaceInfo>((ref) {
  final auth = ref.watch(authProvider);
  if (auth is! AdultSession) throw StateError('no space');
  return auth.space;
});

final onlineProvider = StreamProvider<bool>((ref) async* {
  final sync = ref.watch(servicesProvider).sync;
  yield sync.online;
  yield* sync.onlineChanges;
});

final balancesProvider = StreamProvider<Map<String, int>>((ref) {
  final s = ref.watch(servicesProvider);
  return s.db.watchBalances(ref.watch(spaceProvider).id);
});

final playersProvider = StreamProvider<List<Player>>((ref) {
  final s = ref.watch(servicesProvider);
  return s.db.watchPlayers(ref.watch(spaceProvider).id);
});

final outboxCountProvider = StreamProvider<int>((ref) {
  final s = ref.watch(servicesProvider);
  return s.db.watchOutboxCount(ref.watch(spaceProvider).id);
});
