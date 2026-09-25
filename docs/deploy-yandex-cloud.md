# Развёртывание на виртуальной машине Yandex Cloud

Около 15 минут. Нужна ВМ с Ubuntu 22.04 или 24.04, минимум 2 vCPU и 2 ГБ RAM, диск от 20 ГБ и публичный IP.

## 1. Открыть порты

Консоль Yandex Cloud → Compute Cloud → ваша ВМ → «Сеть» → группа безопасности. Разрешить входящие TCP-порты:

- **22** — SSH, лучше только с вашего IP;
- **80** — нужен для выпуска сертификата HTTPS;
- **443** — само API.

Если группы безопасности нет, всё открыто по умолчанию.

## 2. Зайти на сервер

```bash
ssh <логин>@<публичный-IP>
```

Логин — тот, что указан при создании ВМ (часто `yc-user` или ваш).

## 3. Дать серверу доступ к репозиторию (только чтение)

Репозиторий приватный, поэтому серверу нужен собственный ключ. Выполните на сервере:

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C fantikpay-server
cat ~/.ssh/id_ed25519.pub
```

Скопируйте выведенную строку и добавьте её в GitHub: репозиторий → Settings → Deploy keys → Add deploy key. Галочку «Allow write access» **не ставьте**.

## 4. Скачать код и запустить

```bash
sudo apt-get update && sudo apt-get install -y git
git clone -b claude/software-technical-implementation-sw2sny git@github.com:bredikhinav/GameNFC.git ~/fantikpay
cd ~/fantikpay
sudo bash deploy/install.sh
```

Когда ветку сольют в `main`, уберите `-b claude/…` и сделайте `git checkout main`.

Скрипт сам:

- ставит Docker (образы качает через зеркало, потому что Docker Hub из России доступен не всегда);
- генерирует пароли базы и секрет JWT в файл `.env` (права 600, в git он не попадает);
- на маленькой ВМ добавляет swap;
- собирает и запускает API, PostgreSQL, Redis, фоновые задания, ежедневный бэкап и Caddy с HTTPS.

В конце скрипт печатает адрес. Пока своего домена нет, адрес будет вида `https://158-160-1-2.sslip.io`: это бесплатное имя, которое указывает на IP вашего сервера, и сертификат на него выдаётся автоматически.

## 5. Проверить

- `https://<адрес>/health` → `{"status":"ok"}`.
- Демо-семья для проверки:
  `sudo docker compose exec api python -m app.cli seed-demo` (вход `demo@fantikpay.ru` / `demo12345`). На боевом сервере её потом лучше удалить: у неё известный пароль.
- Приложение: `flutter run --dart-define=API_URL=https://<адрес>`.

## Обновление

```bash
cd ~/fantikpay && sudo bash deploy/install.sh
```

Скрипт подтягивает свежий код из той же ветки и перезапускает сервисы. Данные и `.env` не трогаются.

## Когда купите домен fantikpay.ru

1. В DNS домена создайте A-запись `fantikpay.ru` → публичный IP сервера. Сделать это можно, например, в Yandex Cloud DNS.
2. На сервере: `cd ~/fantikpay && sudo FP_DOMAIN=fantikpay.ru bash deploy/install.sh`.
3. Пересоберите приложение без `API_URL`: по умолчанию оно ходит на `https://fantikpay.ru`.

Сделайте IP сервера статическим (консоль → «Сеть» → «IP-адреса» → «Сделать статическим»). Иначе после остановки ВМ адрес сменится.

## Полезное

| Что | Команда (из `~/fantikpay`) |
| --- | --- |
| Состояние | `sudo docker compose ps` |
| Логи API | `sudo docker compose logs -f api` |
| Сверка балансов | `sudo docker compose exec api python -m app.cli reconcile` |
| Партия карт | `sudo docker compose exec api python -m app.cli generate-batch --name "Партия 1" --count 100 --out /tmp/b.csv`, затем `sudo docker compose cp api:/tmp/b.csv .` |
| Бэкапы | `~/fantikpay/backups/*.dump`, хранятся 14 дней. Копируйте их за пределы сервера, например в Yandex Object Storage |
| Восстановить из бэкапа | `sudo docker compose exec -T db pg_restore -U fantik -d fantikpay --clean < backups/<файл>.dump` |

## Сервер уже занят другим сервисом

Скрипт не трогает уже установленный Docker (не меняет настройки и не перезапускает). Если порты 80/443 заняты, он останавливается до каких-либо изменений. В этом случае есть два пути:

- **Отдельная ВМ** — самый безопасный вариант, чужой сервис никак не затрагивается.
- **Через существующий веб-сервер** (nginx и т. п.): ФантикПэй запускается без Caddy на `127.0.0.1:8000`, а в конфигурацию веб-сервера добавляется отдельный `server` для своего домена или поддомена. Такую настройку лучше делать по выводу диагностики с конкретного сервера.
