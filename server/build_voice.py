#!/usr/bin/env python3
"""Список фраз для озвучки узбекского голоса — и сборка банка из готового аудио.

ЗАЧЕМ. Узбекского голоса в iOS нет (проверено перечислением на 26.2: 68
голосов, 48 языков, из тюркских только турецкий), поэтому узбекские фразы
читает турецкий синтезатор с переписанной орфографией. Понятно, но чужим
голосом. Приложение при этом говорит ЗАКРЫТЫМ словарём, а значит синтез на
телефоне не нужен вовсе: словарь озвучивается один раз заранее, а в дороге
проигрываются готовые файлы. Это ещё и дешевле для батареи — ноль вычислений
против работы синтезатора на каждую фразу.

ГЛАВНОЕ ПРАВИЛО ЭТОГО ФАЙЛА: список фраз выводится ИЗ КАТАЛОГА ПЕРЕВОДОВ, а не
пишется руками. Рукописный список разъедется с приложением на первой же новой
фразе — и голос замолчит там, где никто не заметит. Здесь же расхождение видно
сразу: ключа нет в каталоге — скрипт падает.

ПОЧЕМУ СЛОВАРЬ МАЛЕНЬКИЙ. Дистанция в оповещении округляется (шаг 50 м до 400,
дальше 100 м) — произносимых чисел всего четырнадцать. Тип и направление
пишутся ОДНИМ куском («Kamera oldinda o‘ngda»), число — вторым («uch yuz metr»).
Фраза складывается из двух файлов, и единственный шов приходится туда, где
живая речь и сама делает паузу.

ИСПОЛЬЗОВАНИЕ:

    python3 server/build_voice.py text     # текст для озвучки (в консоль)
    python3 server/build_voice.py manifest # соответствие «фраза → имя файла»

Дальше текст отдаётся диктору или сервису синтеза, готовое аудио кладётся в
RadarMap/Resources/Voice/uz/, и приложение начинает его проигрывать. Чего в
банке нет — по-прежнему читает синтезатор, так что неполный банк ничего не
ломает: он просто улучшает то, что успел покрыть.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Shared" / "Localizable.xcstrings"


def uz(key: str) -> str:
    """Узбекский перевод ключа. Нет перевода — это ошибка сборки, а не пропуск."""
    entry = STRINGS.get(key)
    if entry is None:
        raise SystemExit(f"нет ключа в каталоге: {key!r}")
    value = (entry.get("localizations", {}).get("uz", {})
             .get("stringUnit", {}).get("value"))
    if not value:
        raise SystemExit(f"нет узбекского перевода: {key!r}")
    return value


STRINGS = json.loads(CATALOG.read_text())["strings"]

# --- Числительные: те же корни, что в UzbekSpeech.numeral (Swift) ---
ONES = ["nol", "bir", "ikki", "uch", "to‘rt", "besh",
        "olti", "yetti", "sakkiz", "to‘qqiz"]
TENS = ["", "o‘n", "yigirma", "o‘ttiz", "qirq", "ellik",
        "oltmish", "yetmish", "sakson", "to‘qson"]


def numeral(value: int) -> str:
    """Число словами по-узбекски. Дубль UzbekSpeech.numeral — и он обязан
    совпадать: по этим же словам приложение ищет файл в банке."""
    parts, rest = [], value
    if rest >= 1000:
        thousands = rest // 1000
        parts.append("ming" if thousands == 1 else f"{ONES[thousands]} ming")
        rest %= 1000
    if rest >= 100:
        hundreds = rest // 100
        parts.append("yuz" if hundreds == 1 else f"{ONES[hundreds]} yuz")
        rest %= 100
    if rest >= 10:
        parts.append(TENS[rest // 10])
        rest %= 10
    if rest > 0 or not parts:
        parts.append(ONES[rest])
    return " ".join(parts)


def distances() -> list[int]:
    """Что реально произносится. LocationService округляет дистанцию шагом 50 м
    до 400 и шагом 100 м дальше — других чисел в оповещении не бывает."""
    return list(range(50, 400, 50)) + list(range(400, 1100, 100))


def speeds() -> list[int]:
    """Скорость в срочной фразе округляется до пяти: «восемьдесят семь» и
    «восемьдесят пять» за рулём неразличимы, а словарь падает вчетверо.

    Снизу — порог, ниже которого приложение о скорости вообще не говорит
    (AppConfig.speakSpeedThresholdKmh = 20); сверху — 180, дальше на дорогах
    Узбекистана не ездят, а если ездят, одна фраза уйдёт синтезатору."""
    return list(range(20, 185, 5))


# Типы камер: полное имя (обычная фраза) и короткое (краткая, городская).
KIND_KEYS = ["Стационарная камера", "Стационарный радар",
             "Интеллектуальная камера + радар", "Передвижной радар",
             "Тренога", "Пост ДПС", "ДТП"]
SHORT_KEYS = ["Камера", "Радар"]
DIRECTION_KEYS = ["впереди", "впереди справа", "впереди слева"]

# Готовые фразы целиком — короткие и произносятся часто.
WHOLE_KEYS = ["Маршрут перестроен", "Вы прибыли", "Превышение скорости",
              "Спасибо!", "Отметка убрана", "Не отправилось, нет связи"]


def phrases() -> list[tuple[str, str]]:
    """Пары «имя файла → что произнести». Имя — то, по чему приложение ищет."""
    items: list[tuple[str, str]] = []

    # 1. Тип + направление одним куском.
    for kind in KIND_KEYS + SHORT_KEYS:
        for direction in DIRECTION_KEYS:
            items.append((f"kind_{slug(uz(kind))}_{slug(uz(direction))}",
                          spoken(f"{uz(kind)} {uz(direction)}")))
    # Краткая форма без направления — город, где говорят коротко.
    for kind in SHORT_KEYS:
        items.append((f"kind_{slug(uz(kind))}", spoken(uz(kind))))

    # 2. Расстояния.
    for metres in distances():
        items.append((f"dist_{metres}", f"{numeral(metres)} metr"))

    # 3. Скорость и лимит в срочной фразе.
    for value in speeds():
        items.append((f"speed_{value}", numeral(value)))

    # 4. Обёртки и отдельные фразы.
    items.append(("prefix_crowd", uz("Отметка водителей: %@").replace("%@", "").strip(" :")))
    items.append(("group_ahead", uz("Камеры впереди, %lld метров").replace("%lld metr", "").strip(" ,")))
    for key in WHOLE_KEYS:
        items.append((f"say_{slug(uz(key))}", uz(key)))

    return items


def spoken(text: str) -> str:
    """Как это должно звучать. «Интеллектуальная камера + радар» в каталоге
    записана со знаком «+» — синтезатор прочтёт его словом «плюс», а диктор
    споткнётся. Для озвучки заменяем союзом."""
    return text.replace(" + ", " va ")


def slug(text: str) -> str:
    """Имя файла из фразы: только латиница, цифры и подчёркивание."""
    keep = []
    for character in text.lower():
        if character.isalnum() and character.isascii():
            keep.append(character)
        elif character in " -":
            keep.append("_")
    return "".join(keep).strip("_")


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "text"
    items = phrases()

    if mode == "text":
        # Формат под сервисы синтеза: одна фраза на строку, номер отдельно —
        # чтобы скачанный файл можно было опознать. Блоками по 25: у бесплатных
        # тарифов есть лимит на длину, и упереться в него лучше на четверти
        # текста, чем на всём.
        for start in range(0, len(items), 25):
            block = items[start:start + 25]
            print(f"\n===== БЛОК {start // 25 + 1} =====")
            for index, (_, text) in enumerate(block, start=start + 1):
                print(f"{index}. {text}")
    elif mode == "manifest":
        print(json.dumps([{"file": name, "text": text} for name, text in items],
                         ensure_ascii=False, indent=2))
    else:
        raise SystemExit("режимы: text | manifest")

    print(f"\nвсего фраз: {len(items)}", file=sys.stderr)


if __name__ == "__main__":
    main()
