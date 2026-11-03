#!/usr/bin/env python3
"""Вход в панель модератора: пароль, сессии, ограничение попыток.

Отдельным модулем, потому что это единственная часть панели, ошибка в которой
стоит не «неудобно», а «чужой человек снимает камеры с карты».

Устройство намеренно скучное и целиком на стандартной библиотеке:

* **Пароль хранится хэшем** (scrypt с солью), а не текстом. Файл конфигурации
  на VPS могут прочитать по неосторожности — из хэша пароль не достать.
* **Сессия — подписанная кука, а не запись в памяти.** Первая версия держала
  токены в памяти процесса, и это оказалось прямой ошибкой: каждый перезапуск
  панели (а её перезапускает любой деплой) выкидывал модератора на форму
  входа. Со стороны человека это неотличимо от «пароль не работает» — он вводит
  верный пароль и снова видит форму. Теперь в куке лежит срок годности с
  HMAC-подписью: сервер проверяет её арифметикой, ничего не помня.
* **Смена пароля обрывает все сессии.** Секрет подписи перевыпускается вместе с
  паролем — иначе украденную куку нельзя было бы отозвать вовсе.
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
from urllib.parse import quote, unquote

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
    """Записать хэш пароля, сохранив остальные ключи файла.

    Заодно перевыпускает секрет подписи сессий: смена пароля обязана обрывать
    уже выданные куки, иначе украденная сессия переживёт смену пароля — то
    есть единственное действие, которым её можно было отозвать.
    """
    path = path or CONFIG_PATH
    config = read_config(path)
    config["password_hash"] = hash_password(password)
    config["session_secret"] = secrets.token_urlsafe(32)
    # Права до записи содержимого: между созданием файла и chmod не должно быть
    # окна, в котором хэш лежит доступным всем.
    _write_config(config, path)
    return path


# --------------------------------------------------------------------------
# Люди
# --------------------------------------------------------------------------
#
# Учётная запись перестала быть одна, и это не про удобство. Журнал панели
# пишет «edit-withdraw #5», а на вопрос «кто снял» ответить было нечем: пароль
# один, значит все действия одинаковы и безымянны. Пока модератор один, это
# терпимо; на втором человеке становится дырой — снятую чужую правку не
# отличить от своей.
#
# Формат прежний, KEY=VALUE: `user_иван=scrypt$...`. Старый `password_hash`
# остаётся и работает как учётная запись владельца — иначе обновление панели
# выкинуло бы из неё единственного человека.

OWNER = "владелец"


def accounts(config=None):
    """Кто может войти → {имя: хэш}. Пусто — панель ещё не настроена."""
    config = config if config is not None else read_config()
    out = {}
    legacy = config.get("password_hash")
    if legacy:
        out[OWNER] = legacy
    for key, value in config.items():
        if key.startswith("user_") and len(key) > 5 and value:
            out[key[5:]] = value
    return out


def who_signs_in(name, password, config=None):
    """Проверить имя и пароль → имя вошедшего или None.

    Пустое имя — вход владельца: так входили до появления имён, и ломать это
    ради формы нельзя.

    Перебираем ВСЕ записи, даже когда имя не найдено: ранний выход отвечал бы
    заметно быстрее на несуществующее имя, и по времени ответа список людей
    вычитывался бы снаружи.
    """
    people = accounts(config)
    if not people:
        return None
    wanted = (name or "").strip() or OWNER
    matched = None
    for account, stored in sorted(people.items()):
        if check_password(password, stored) and account == wanted:
            matched = account
    return matched


def write_account(name, password, path=None):
    """Завести или сменить пароль человека."""
    name = (name or "").strip()
    if not name or "=" in name or name == OWNER:
        raise ValueError("имя пустое, с «=» или занято владельцем")
    path = path or CONFIG_PATH
    config = read_config(path)
    config[f"user_{name}"] = hash_password(password)
    _write_config(config, path)
    return path


def drop_account(name, path=None):
    path = path or CONFIG_PATH
    config = read_config(path)
    if config.pop(f"user_{(name or '').strip()}", None) is None:
        return False
    _write_config(config, path)
    return True


def _write_config(config, path):
    body = "".join(f"{key}={value}\n" for key, value in sorted(config.items()))
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(body)


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
    """Сессии без состояния: кука — это срок годности плюс подпись.

    Проверка сводится к арифметике, поэтому перезапуск панели никого не
    разлогинивает. Смена пароля владельца перевыпускает секрет подписи, и все
    прежние куки перестают сходиться.

    В подпись входит и ТЕКУЩИЙ хэш пароля вошедшего, а сверяется кука со
    списком учёток на каждом запросе: убранный модератор выходит сразу, а
    сменивший пароль теряет старые куки — раньше оба оставались в панели до
    конца срока куки, 12 часов (аудит 38B, M-6).
    """

    def __init__(self, ttl=SESSION_TTL, secret=None, people=None):
        self.ttl = ttl
        self._secret = secret          # для тестов; иначе берётся из конфига
        self._people = people          # для тестов: {имя: хэш}; иначе — из конфига
        self._attempts = {}            # адрес → [время неудачных попыток]

    def _key(self):
        return (self._secret or session_secret()).encode()

    def _stored(self, name):
        """Хэш пароля учётки сейчас; None — учётки больше нет. Пустое имя —
        кука владельца, выданная до появления имён."""
        people = self._people if self._people is not None else accounts()
        return people.get(name or OWNER)

    def _sign(self, payload, stored):
        message = (payload + "\n" + stored).encode()
        return hmac.new(self._key(), message, hashlib.sha256).hexdigest()[:32]

    def issue(self, now=None, name=""):
        """Кука несёт срок И ИМЯ вошедшего.

        Имя внутри подписи, а не рядом с ней: иначе его можно было бы
        подменить в браузере и подписать чужие действия чужим именем — то
        есть ровно сломать то, ради чего имена и заводились.
        """
        now = now if now is not None else time.time()
        payload = str(int(now + self.ttl))
        if name:
            # Имя в куке — ПРОЦЕНТНЫМ кодированием. Заголовки HTTP это
            # latin-1, и кириллическое имя роняло весь ответ на входе: человек
            # вводил верный пароль и получал оборванное соединение.
            payload += "|" + quote(name, safe="")
        # Учётки нет — подпись всё равно ставится, но `valid` такую куку не
        # пустит: сверять не с чем.
        return payload + "." + self._sign(payload, self._stored(name) or "")

    def valid(self, token, now=None):
        now = now if now is not None else time.time()
        if not token or "." not in token:
            return False
        payload, _, signature = token.partition(".")
        expiry, _, quoted = payload.partition("|")
        stored = self._stored(unquote(quoted))
        # Сначала подпись, потом срок: сравнение постоянного времени и никакой
        # веры содержимому куки до проверки. Имя выше читается только чтобы
        # найти хэш для подписи — подменённое имя подпись не пройдёт. Учётки
        # нет — подпись всё равно считается: по времени ответа список людей не
        # вычитывается (как в who_signs_in).
        signed = hmac.compare_digest(self._sign(payload, stored or ""), signature)
        if stored is None or not signed:
            return False
        try:
            return int(expiry) > now
        except ValueError:
            return False

    def name_of(self, token):
        """Кто вошёл по этой куке. Пусто — кука без имени, то есть выданная
        до появления учётных записей: такой человек и есть владелец."""
        if not self.valid(token):
            return ""
        payload = token.partition(".")[0]
        return unquote(payload.partition("|")[2])

    def drop(self, token=None):
        """Выход: перевыпускаем секрет, и все выданные куки перестают сходиться.

        Без этого «выход» только просил браузер забыть куку — а сама кука
        оставалась годной до истечения срока, то есть уведённая сессия
        переживала выход. Модератор один, поэтому «выйти» и «выйти везде»
        здесь совпадают.
        """
        if self._secret is None:
            rotate_session_secret()

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


def _store_secret(path):
    """Завести новый секрет подписи и сохранить его. Возвращает секрет даже
    если записать не удалось: сессии тогда проживут до перезапуска, но панель
    обязана работать."""
    secret = secrets.token_urlsafe(32)
    config = read_config(path)
    config["session_secret"] = secret
    body = "".join(f"{key}={value}\n" for key, value in sorted(config.items()))
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(body)
    except OSError:
        pass
    return secret


def session_secret(path=None):
    """Секрет подписи кук; заводится при первом обращении (панель с прошлой
    версии его не имеет)."""
    path = path or CONFIG_PATH
    return read_config(path).get("session_secret") or _store_secret(path)


def rotate_session_secret(path=None):
    """Оборвать все выданные куки. Так работает выход: подписанный токен нельзя
    отозвать поштучно, а модератор у панели один — «выйти» и «выйти везде» для
    него одно и то же."""
    return _store_secret(path or CONFIG_PATH)


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
