#!/usr/bin/env python3
"""Вход в панель модератора: пароль, сессии, ограничение попыток.

Отдельным модулем, потому что это единственная часть панели, ошибка в которой
стоит не «неудобно», а «чужой человек снимает камеры с карты».

Устройство намеренно скучное и целиком на стандартной библиотеке:

* **Пароль хранится хэшем** (scrypt с солью), а не текстом. Файл конфигурации
  на VPS могут прочитать по неосторожности — из хэша пароль не достать.
* **Сессия — случайный токен в памяти процесса.** Перезапуск панели разлогинит
  всех, и это правильно: панель перезапускают редко, а «вечная» сессия в файле
  переживает и утечку файла.
* **Ограничение попыток по адресу.** Пароль у панели один, подбирать его будут
  именно перебором.
* **Сравнение хэшей — постоянного времени** (`compare_digest`): разница в
  миллисекундах на неверном пароле — это утечка, пусть и медленная.

ГЛАВНОЕ ОГРАНИЧЕНИЕ, которое не лечится кодом: **по открытому HTTP пароль
уходит открытым текстом**. Пока у сервера нет домена и сертификата, вход не
защищает панель в сети — он готовит её к тому моменту, когда сертификат
появится (server/HTTPS.md). До тех пор панель остаётся на 127.0.0.1 и
доступна только через ssh-туннель, а `require_secure()` не даёт открыть её
наружу по HTTP по недосмотру.

Задать пароль (на VPS, спросит дважды и ничего не покажет на экране):

    python3 admin.py --set-password
"""
import base64
import getpass
import hashlib
import hmac
import os
import secrets
import time

CONFIG_PATH = os.environ.get("RADARMAP_ADMIN_CONF", "/opt/radarmap/admin.conf")

# Параметры scrypt: 2^15 — примерно 100 мс на проверку. Для входа человека
# незаметно, для перебора — потолок в несколько попыток в секунду даже с
# украденным хэшем.
SCRYPT_N, SCRYPT_R, SCRYPT_P = 1 << 15, 8, 1
# scrypt требует 128·N·r памяти — здесь 32 МБ, ровно в предел OpenSSL по
# умолчанию, и он его отвергает. Просим с запасом, иначе вход падает на
# ровном месте с невнятным «memory limit exceeded».
SCRYPT_MAXMEM = 64 << 20

SESSION_TTL = 12 * 3600        # рабочий день; дальше вход заново
SESSION_COOKIE = "radarmap_admin"
MAX_ATTEMPTS = 8               # неверных попыток с одного адреса…
ATTEMPT_WINDOW = 15 * 60       # …за это время, дальше отказ без проверки пароля


# --------------------------------------------------------------------------
# Конфигурация
# --------------------------------------------------------------------------

def read_config(path=None):
    """KEY=VALUE, по строке. Отсутствующий файл — пустая конфигурация: панель
    обязана подняться и сказать «пароль не задан», а не упасть."""
    config = {}
    try:
        with open(path or CONFIG_PATH, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                config[key.strip()] = value.strip()
    except OSError:
        pass
    return config


def write_password(password, path=None):
    """Записать хэш пароля, сохранив остальные ключи файла."""
    path = path or CONFIG_PATH
    config = read_config(path)
    config["password_hash"] = hash_password(password)
    body = "".join(f"{key}={value}\n" for key, value in sorted(config.items()))
    # Права до записи содержимого: между созданием файла и chmod не должно быть
    # окна, в котором хэш лежит доступным всем.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(body)
    return path


# --------------------------------------------------------------------------
# Пароль
# --------------------------------------------------------------------------

def hash_password(password, salt=None):
    """scrypt$соль$хэш — в одну строку, чтобы конфиг оставался KEY=VALUE."""
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=SCRYPT_N, r=SCRYPT_R,
                            p=SCRYPT_P, maxmem=SCRYPT_MAXMEM, dklen=32)
    return "scrypt$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(digest).decode()


def check_password(password, stored):
    """Верен ли пароль. Любая неисправность записи — «нет»: испорченный хэш
    не должен превращаться в открытую дверь."""
    if not stored:
        return False
    try:
        scheme, salt_b64, digest_b64 = stored.split("$")
        if scheme != "scrypt":
            return False
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(digest_b64)
    except (ValueError, TypeError):
        return False
    # Пустые соль или хэш — испорченная запись. Без этой проверки scrypt
    # получает dklen=0 и КИДАЕТ исключение: проверка пароля перестаёт быть
    # функцией «да/нет» и роняет обработчик входа, то есть портит панель
    # ровно тем, от чего должна защищать. Найдено тестом на битый хэш.
    if not salt or not expected:
        return False
    actual = hashlib.scrypt(password.encode(), salt=salt, n=SCRYPT_N, r=SCRYPT_R,
                            p=SCRYPT_P, maxmem=SCRYPT_MAXMEM, dklen=len(expected))
    return hmac.compare_digest(actual, expected)


def set_password_interactively(path=None):
    """`admin.py --set-password`: пароль вводит человек, в аргументы командной
    строки он не попадает (оттуда его видно в `ps` любому пользователю)."""
    first = getpass.getpass("Новый пароль панели: ")
    if len(first) < 8:
        return "пароль короче 8 символов — не принят"
    if first != getpass.getpass("Ещё раз: "):
        return "пароли не совпали"
    return f"пароль сохранён: {write_password(first, path)}"


# --------------------------------------------------------------------------
# Сессии и попытки входа
# --------------------------------------------------------------------------

class Sessions:
    """Токены живых сессий. В памяти процесса: перезапуск = общий выход."""

    def __init__(self, ttl=SESSION_TTL):
        self.ttl = ttl
        self._tokens = {}      # токен → время истечения
        self._attempts = {}    # адрес → [время неудачных попыток]

    def issue(self, now=None):
        now = now if now is not None else time.time()
        self._sweep(now)
        token = secrets.token_urlsafe(32)
        self._tokens[token] = now + self.ttl
        return token

    def valid(self, token, now=None):
        now = now if now is not None else time.time()
        if not token:
            return False
        expires = self._tokens.get(token)
        if expires is None:
            return False
        if expires <= now:
            self._tokens.pop(token, None)
            return False
        return True

    def drop(self, token):
        self._tokens.pop(token, None)

    def _sweep(self, now):
        for token, expires in list(self._tokens.items()):
            if expires <= now:
                del self._tokens[token]

    # --- перебор ---

    def blocked(self, address, now=None):
        now = now if now is not None else time.time()
        recent = [t for t in self._attempts.get(address, []) if t > now - ATTEMPT_WINDOW]
        self._attempts[address] = recent
        return len(recent) >= MAX_ATTEMPTS

    def note_failure(self, address, now=None):
        now = now if now is not None else time.time()
        self._attempts.setdefault(address, []).append(now)

    def note_success(self, address):
        self._attempts.pop(address, None)


def cookie_token(header):
    """Токен из заголовка Cookie. Свой разбор вместо http.cookies: нам нужно
    одно значение, а SimpleCookie на кривом заголовке кидает исключение."""
    for part in (header or "").split(";"):
        name, _, value = part.strip().partition("=")
        if name == SESSION_COOKIE:
            return value
    return ""


def require_secure(headers, client_address):
    """Можно ли отдавать панель по этому соединению.

    Пароль по открытому HTTP уходит открытым текстом. Поэтому вход разрешён
    либо локально (ssh-туннель — трафик уже зашифрован туннелем), либо когда
    nginx подтвердил TLS заголовком X-Forwarded-Proto. Иначе панель честно
    отказывает, вместо того чтобы принять пароль и отправить его открытым.
    """
    if (headers.get("X-Forwarded-Proto") or "").lower() == "https":
        return True
    return (client_address or "").startswith("127.") or client_address == "::1"
