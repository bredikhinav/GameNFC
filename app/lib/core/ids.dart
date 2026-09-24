import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();

/// Same namespace and names as the server (app/services/ledger.py), so a phone can create
/// wallet ids offline that match the ones the server will create.
const walletNamespace = '6b1f3f0e-3c5a-4c1e-9a8e-4f0b8f6a2d11';

String persistentWalletId(String playerId) => _uuid.v5(walletNamespace, 'persistent:$playerId');

String sessionWalletId(String sessionId, String playerId) =>
    _uuid.v5(walletNamespace, 'session:$sessionId:$playerId');

String systemWalletId(String spaceId, String kind) => _uuid.v5(walletNamespace, '$kind:$spaceId');
