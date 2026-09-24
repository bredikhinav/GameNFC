/// Error returned by the API with a stable code (see server app/errors.py).
class ApiError implements Exception {
  ApiError(this.code, {this.status = 0, this.details = const {}});

  final String code;
  final int status;
  final Map<String, dynamic> details;

  String get message => errorText(code);

  @override
  String toString() => 'ApiError($code)';
}

/// No connection, timeout, server unreachable: the operation may be queued offline.
class OfflineError implements Exception {
  const OfflineError();

  @override
  String toString() => 'OfflineError';
}

String errorText(String code) => switch (code) {
      'invalid_credentials' => 'Неверная почта или пароль',
      'email_taken' => 'Такая почта уже зарегистрирована',
      'rate_limited' => 'Слишком много попыток. Подождите пару минут',
      'unauthorized' => 'Нужно войти заново',
      'forbidden' => 'Недостаточно прав',
      'insufficient_funds' => 'Не хватает монет',
      'card_blocked' => 'Карта заблокирована',
      'card_not_found' => 'Карта не распознана',
      'card_unlinked' => 'Карта отвязана от игрока',
      'card_not_in_session' => 'Игрок не в этой игре',
      'card_already_linked' => 'Карта уже привязана к игроку',
      'card_uid_mismatch' => 'Похоже на копию карты: чип не совпадает',
      'card_uid_taken' => 'Этот чип уже зарегистрирован',
      'invalid_activation_code' => 'Неверный код с упаковки',
      'limit_exceeded' => 'Превышен дневной лимит переводов',
      'session_not_active' => 'Игра на паузе или уже закончена',
      'session_finished' => 'Игра уже закончена',
      'already_reversed' => 'Операция уже отменена',
      'invalid_code' => 'Код устарел или уже использован',
      'same_player' => 'Нельзя перевести самому себе',
      'player_not_found' => 'Игрок не найден',
      'validation_error' => 'Проверьте введённые данные',
      'offline' => 'Нет сети',
      'offline_limit' => 'Без сети можно потратить не больше лимита. Дождитесь синхронизации',
      'user_not_found' => 'Сначала он должен создать аккаунт в приложении',
      'already_member' => 'Уже добавлен',
      'invalid_amount' => 'Введите сумму',
      'session_not_found' => 'Игра не найдена',
      'transaction_not_found' => 'Операция не найдена',
      _ => 'Что-то пошло не так ($code)',
    };
