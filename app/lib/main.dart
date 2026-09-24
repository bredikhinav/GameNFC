import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'app_state.dart';
import 'core/api.dart';
import 'core/config.dart';
import 'core/ids.dart';
import 'core/storage.dart';
import 'data/db.dart';
import 'data/sync.dart';
import 'nfc/card_reader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  const store = SecureStore();
  var deviceId = await store.read(Keys.deviceId);
  if (deviceId == null) {
    deviceId = newId();
    await store.write(Keys.deviceId, deviceId);
  }
  final db = await AppDb.open();
  final api = Api(store);
  final navigatorKey = GlobalKey<NavigatorState>();
  final services = Services(
    store: store,
    db: db,
    api: api,
    sync: SyncService(db, api),
    reader: Config.debugCards ? DebugCardReader(navigatorKey) : NfcCardReader(),
    deviceId: deviceId,
    navigatorKey: navigatorKey,
  );

  runApp(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(services)],
    child: const _SyncOnResume(child: FantikPayApp()),
  ));
}

/// Send the offline queue when the app comes back to the foreground, when the network
/// returns, and every 30 seconds while something is waiting.
class _SyncOnResume extends ConsumerStatefulWidget {
  const _SyncOnResume({required this.child});

  final Widget child;

  @override
  ConsumerState<_SyncOnResume> createState() => _SyncOnResumeState();
}

class _SyncOnResumeState extends ConsumerState<_SyncOnResume> with WidgetsBindingObserver {
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _kick(onlyIfPending: true));
    _connectivity = Connectivity().onConnectivityChanged.listen((r) {
      if (!r.contains(ConnectivityResult.none)) _kick();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _connectivity?.cancel();
    super.dispose();
  }

  Future<void> _kick({bool onlyIfPending = false}) async {
    final auth = ref.read(authProvider);
    if (auth is! AdultSession) return;
    final s = ref.read(servicesProvider);
    if (onlyIfPending && (await s.db.watchOutboxCount(auth.space.id).first) == 0) return;
    s.sync.kick();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _kick();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
