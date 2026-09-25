# ФантикПэй

Игровой банк для детей на NFC-картах. Карта — это идентификатор игрока, телефон ведущего — терминал, балансы хранятся на сервере. Монеты виртуальные: их нельзя купить или обменять на деньги.

| Папка | Что внутри |
| --- | --- |
| [`server/`](server) | API: FastAPI, PostgreSQL, Redis |
| [`app/`](app) | Мобильное приложение Flutter (Android + iOS), режимы «Банк» и «Игрок» |
| [`docs/`](docs) | [Архитектура](docs/architecture.md) и [технические решения](docs/technical-decisions.md) |
| `docker-compose.yml`, `deploy/` | Развёртывание на одном VPS |

## Как протестировать

Пошаговая инструкция — [docs/testing.md](docs/testing.md). Коротко:

```bash
docker compose -f docker-compose.dev.yml up --build -d
docker compose -f docker-compose.dev.yml exec api python -m app.cli seed-demo   # demo@fantikpay.ru / demo12345
cd app && flutter run --dart-define=API_URL=http://10.0.2.2:8000 --dart-define=DEBUG_CARDS=true
```

## Быстрый старт для разработки

Сервер (нужны PostgreSQL 16 и Redis):

```bash
cd server
uv sync
createdb fantikpay && createdb fantikpay_test   # пользователь fantik/fantik, см. app/config.py
uv run alembic upgrade head
uv run uvicorn app.main:app --reload --port 8000   # документация API: http://localhost:8000/docs
uv run pytest
```

Приложение:

```bash
cd app
flutter pub get
# Эмулятор Android ходит на компьютер по 10.0.2.2. DEBUG_CARDS=true — ввод токена карты вместо NFC.
flutter run --dart-define=API_URL=http://10.0.2.2:8000 --dart-define=DEBUG_CARDS=true
flutter test                                                      # юнит-тесты и отрисовка экранов
flutter test --dart-define=API_URL=http://localhost:8000          # плюс интеграция с живым API
```

На реальном телефоне укажите в `API_URL` IP компьютера в локальной сети. Если в Wi-Fi нет HTTP-доступа к компьютеру, используйте HTTPS-туннель.

## Прод

Пошагово для Yandex Cloud — [docs/deploy-yandex-cloud.md](docs/deploy-yandex-cloud.md).

```bash
sudo bash deploy/install.sh      # Docker, секреты в .env, HTTPS (без домена — <ip>.sslip.io)
docker compose exec api python -m app.cli generate-batch --name "Партия 1" --count 100 --out /tmp/batch.csv
```

Сервер и база должны стоять в России (152-ФЗ). Бэкапы складываются в `./backups` — копируйте их и за пределы сервера.
