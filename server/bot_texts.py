#!/usr/bin/env python3
"""bot_texts.py — все тексты Telegram-бота на двух языках (план 23.1).

Язык человека — `/lang` (хранится в bot.db по хэшу человека, см.
bot_subs.py), иначе `language_code` Telegram: «uz…» — узбекский, всё прочее —
русский (как family_notify.language_of). Узбекский — латиница: ʻ (U+02BB)
после o и g, ʼ (U+02BC) в остальных местах; ASCII-апострофа нет нигде — тест
проверяет.

Ключи обоих языков совпадают, и подстановки {…} в паре — те же (тест):
забытая строка в одном языке — красный тест, а не KeyError в проде.

Здесь же — профиль бота (имя, описания, меню команд), который бот сам
выставляет при запуске (telegram_bot.ensure_profile), и названия городов и
типов отметок.
"""

LANGS = ("ru", "uz")

#: Команды меню — в этом порядке. Описания — в PROFILE[язык]["commands"].
COMMANDS = ("near", "report", "metan", "pereval", "city", "my", "app", "lang", "help", "privacy", "stop")

PROFILE = {
    "ru": {
        "name": "RadarMap: радары рядом",
        "short": ("Радары, треноги и посты в Узбекистане — от водителей. "
                  "Отправьте геопозицию — покажем, что рядом."),
        "description": (
            "Радары, треноги и посты ДПС в Узбекистане — отмечают сами водители.\n\n"
            "📍 Отправьте геопозицию — покажу, что рядом: живые отметки, стационарные камеры, "
            "перекрытия и метан.\n"
            "📡 Включите трансляцию геопозиции — раз в минуту пришлю, что нового впереди.\n"
            "⛽ /metan — есть ли газ на ближайших АГНКС.\n"
            "⛰ /pereval — погода на Камчике и Тахтакараче.\n"
            "🏙 /city — подтверждённые треноги и посты вашего города.\n\n"
            "Ваш Telegram-id открыто не хранится, геопозиция — только для ответа."),
        "commands": {
            "near": "Что рядом: радары, камеры, метан",
            "report": "Отметить радар, треногу, пост",
            "metan": "Метан рядом: есть ли газ",
            "pereval": "Перевалы Камчик и Тахтакарача",
            "city": "Подписка на город",
            "my": "Мои подписки",
            "app": "Приложение RadarMap",
            "lang": "Язык: русский / oʻzbekcha",
            "help": "Что умеет бот",
            "privacy": "Что мы храним",
            "stop": "Отписаться от всего",
        },
    },
    "uz": {
        "name": "RadarMap: yaqindagi radarlar",
        "short": ("Oʻzbekistondagi radarlar, uch oyoqlar va postlar — haydovchilardan. "
                  "Joylashuvni yuboring — yaqinini koʻrsatamiz."),
        "description": (
            "Oʻzbekistondagi radarlar, uch oyoq kameralar va YPX postlari — haydovchilar belgilaydi.\n\n"
            "📍 Joylashuvni yuboring — yaqinini koʻrsataman: belgilar, kameralar, yopiq yoʻllar, metan.\n"
            "📡 Joylashuv translyatsiyasi — har daqiqada oldindagi yangiliklar.\n"
            "⛽ /metan — yaqindagi AGTKSlarda gaz bormi.\n"
            "⛰ /pereval — Qamchiq va Taxtaqoracha dovonlarida ob-havo.\n"
            "🏙 /city — shahringizdagi tasdiqlangan uch oyoqlar va postlar.\n\n"
            "Telegram-id ochiq saqlanmaydi, joylashuv — faqat javob uchun."),
        "commands": {
            "near": "Yaqinda nima bor: radarlar, kameralar, metan",
            "report": "Radar, uch oyoq, postni belgilash",
            "metan": "Yaqindagi metan: gaz bormi",
            "pereval": "Qamchiq va Taxtaqoracha dovonlari",
            "city": "Shaharga obuna",
            "my": "Obunalarim",
            "app": "RadarMap ilovasi",
            "lang": "Til: oʻzbekcha / русский",
            "help": "Bot nimalar qila oladi",
            "privacy": "Nimalarni saqlaymiz",
            "stop": "Hammasidan obunani bekor qilish",
        },
    },
}

#: Bot API: пределы длины полей профиля (тест сверяет).
PROFILE_LIMITS = {"name": 64, "short": 120, "description": 512, "command": 256}

#: Тип отметки API → подпись. Порядок — кнопки «что здесь?».
KIND_NAMES = {
    "ru": {"radar": "📡 Радар", "tripod": "📷 Тренога", "post": "👮 Пост ДПС", "accident": "💥 ДТП",
           "closure": "⛔ Перекрыто", "roadwork": "🚧 Ремонт", "cng": "⛽ Метан"},
    "uz": {"radar": "📡 Radar", "tripod": "📷 Uch oyoq kamera", "post": "👮 YPX posti", "accident": "💥 YTH",
           "closure": "⛔ Yoʻl yopiq", "roadwork": "🚧 Taʼmir", "cng": "⛽ Metan"},
}
#: Те же без значка — внутри фразы «Тренога ещё стоит?».
KIND_WORDS = {
    "ru": {"radar": "Радар", "tripod": "Тренога", "post": "Пост ДПС", "accident": "ДТП"},
    "uz": {"radar": "Radar", "tripod": "Uch oyoq kamera", "post": "YPX posti", "accident": "YTH"},
}
CNG_NAMES = {
    "ru": {"gas": "✅ Газ есть", "nogas": "❌ Газа нет", "queue15": "⏳ Очередь ~15 мин",
           "queue60": "⏳ Очередь 30+ мин"},
    "uz": {"gas": "✅ Gaz bor", "nogas": "❌ Gaz yoʻq", "queue15": "⏳ Navbat ~15 daq",
           "queue60": "⏳ Navbat 30+ daq"},
}
#: Тип стационарной камеры из базы (поле type) → слово.
CAMERA_NAMES = {
    "ru": {"Стационар радар": "радар", "Стационар камера": "камера",
           "Интеллектуал + радар": "умная камера + радар"},
    "uz": {"Стационар радар": "radar", "Стационар камера": "kamera",
           "Интеллектуал + радар": "intellektual kamera + radar"},
}
HAZARD_NAMES = {
    "ru": {"ice": "гололёд", "snow": "снег", "fog": "туман", "wind": "сильный ветер"},
    "uz": {"ice": "yaxmalak", "snow": "qor", "fog": "tuman", "wind": "kuchli shamol"},
}
#: Города подписки — те же, что у канала (telegram_publish.CITIES), по-узбекски.
CITY_NAMES_UZ = {
    "Ташкент": "Toshkent", "Самарканд": "Samarqand", "Бухара": "Buxoro", "Наманган": "Namangan",
    "Андижан": "Andijon", "Фергана": "Fargʻona", "Нукус": "Nukus", "Карши": "Qarshi",
    "Термез": "Termiz", "Ургенч": "Urganch", "Джизак": "Jizzax", "Навои": "Navoiy",
    "Гулистан": "Guliston",
}

TEXTS = {
    "ru": {
        # --- отметка (было) ---
        "start": ("Отправьте геопозицию кнопкой «📍 Отправить геопозицию» внизу — покажу, что рядом: "
                  "радары, треноги, посты, камеры и метан. Там же одной кнопкой можно отметить, "
                  "что видите. Все команды — в меню."),
        "pick": "Что здесь?",
        "pick_cng": "Как на заправке?",
        "pick_cng_at": "Как на заправке «{name}»?",
        "expired": "Точка устарела — отправьте геопозицию ещё раз.",
        "limit": "На сегодня отметок достаточно — спасибо!",
        "slow": "Не так часто — подождите пару минут и нажмите ещё раз.",
        "busy": "Не так часто — отметок от вас сейчас достаточно, попробуйте позже.",
        "cng_far": "Рядом нет заправки метаном в нашей базе — отправьте геопозицию у самой колонки.",
        "cng_unavailable": "Отметки о метане сейчас не принимаются — попробуйте позже.",
        "created": ("Отмечено ✅ — увидят водители рядом. Подтвердит второй водитель — "
                    "отметка проживёт дольше."),
        "merged": "Рядом уже отмечено — ваш голос засчитан.",
        "amended": "Тип уточнён.",
        "cng_ok": "Спасибо! Статус заправки обновлён.",
        "error": "Не получилось отправить — попробуйте ещё раз чуть позже.",
        # --- меню и справка (23.1) ---
        "kb_location": "📍 Отправить геопозицию",
        "kb_metan": "⛽ Метан рядом",
        "help": ("Что умеет бот:\n"
                 "📍 Геопозиция — что рядом в 5 км: отметки водителей, стационарные камеры, "
                 "перекрытия, метан. Кнопка «Отметить, что видите» — под ответом.\n"
                 "📡 Трансляция геопозиции — раз в минуту новое впереди по ходу; проехали отметку — "
                 "спрошу, стоит ли она ещё.\n"
                 "/metan — ближайшие АГНКС: есть ли газ, очередь.\n"
                 "/pereval — Камчик и Тахтакарача; можно подписаться на предупреждения.\n"
                 "/city — подтверждённые треноги и посты города, с 7:00 до 23:00.\n"
                 "/my — ваши подписки, /stop — отписаться от всего.\n"
                 "/lang — язык, /privacy — что мы храним, /app — приложение."),
        "privacy": ("Что мы храним:\n"
                    "• Ваш Telegram-id открыто не хранится: вместо него — необратимый хэш, который "
                    "меняется раз в 30 дней.\n"
                    "• Геопозиция нужна для одного ответа и не записывается ни в базу, ни в журнал. "
                    "Во время трансляции она живёт только в памяти, пока трансляция идёт.\n"
                    "• Подписки на город и перевалы: хэш чата, название города или перевала и номер "
                    "чата — зашифрованным. Без ваших команд 55 дней подписка удаляется сама; /stop — "
                    "сразу.\n"
                    "• Отметки живут часы, как в приложении, и уходят без имени.\n"
                    "Подробно: {url}"),
        "app_soon": ("📱 Приложение RadarMap для iPhone — скоро в App Store. В нём то, чего нет у бота: "
                     "голос за рулём, CarPlay и предупреждения о камерах в фоне, даже без интернета."),
        "app_link": ("📱 RadarMap для iPhone: {url}\nВ приложении то, чего нет у бота: голос за рулём, "
                     "CarPlay и предупреждения о камерах в фоне, даже без интернета."),
        "lang_pick": "Выберите язык:",
        "lang_set": "Готово: пишу по-русски.",
        "need_location": "Отправьте геопозицию кнопкой «📍 Отправить геопозицию» внизу.",
        "need_location_report": ("Отправьте геопозицию кнопкой «📍 Отправить геопозицию» внизу — "
                                 "и выберите, что там."),
        "off": ("Эта функция сейчас выключена. Отметить радар, треногу или пост можно как обычно — "
                "отправьте геопозицию."),
        "unknown_busy": "Сейчас не получилось — попробуйте чуть позже.",
        # --- «что рядом» (23.2) ---
        "near_head": "📍 В радиусе {radius}:",
        "near_none": "Отметок водителей нет.",
        "near_live_down": "Отметки водителей сейчас не загрузились — попробуйте чуть позже.",
        "near_more": "…и ещё {n}",
        "confirmed": "подтверждена",
        "unconfirmed": "отметка водителя, не подтверждена",
        "ago_min": "{n} мин назад",
        "ago_hours": "{h} ч {m} мин назад",
        "until": "до {time}",
        "cameras": "📷 Стационарных камер: {n}, ближайшая — {dist}",
        "cameras_none": "📷 Стационарных камер рядом нет.",
        "cameras_down": "📷 База камер сейчас недоступна.",
        "speed": "{n} км/ч",
        "metan_line": "⛽ Метан: «{name}» {dist} — {status}",
        "metan_none": "⛽ АГНКС в радиусе нет.",
        "cng_gas": "газ есть",
        "cng_nogas": "газа нет",
        "cng_unknown": "нет данных",
        "cng_queue": "очередь ~{n} мин",
        "btn_mark": "Отметить, что видите",
        "btn_further": "Дальше — 15 км",
        "near_slow": "«Что рядом» можно обновлять раз в 20 секунд. Отметить эту точку:",
        # --- метан (23.3) ---
        "metan_head": "⛽ Ближайшие АГНКС:",
        "metan_empty": "В 15 км от вас АГНКС в нашей базе нет.",
        "metan_down": "Список АГНКС сейчас недоступен — попробуйте позже.",
        "metan_hint": "Отметить статус можно, стоя у заправки (до 300 м).",
        "btn_cng_mark": "Отметить статус: {name}",
        "cng_station": "АГНКС",
        "cng_unconfirmed": "не подтверждено",
        "cng_too_far": "Отметить статус можно, стоя у самой заправки — отправьте геопозицию оттуда.",
        # --- трансляция (23.4) ---
        "live_on": ("📡 Трансляция принята: раз в минуту пришлю, что нового впереди по ходу. "
                    "Остановить — /stop или выключить трансляцию."),
        "live_ahead": "🚗 Впереди по ходу:",
        "live_still": "{kind} ещё стоит?",
        "btn_yes": "Да",
        "btn_no": "Нет",
        "btn_unseen": "Не видел",
        "vote_thanks": "Спасибо! Ответ увидят водители рядом.",
        "vote_skip": "Понятно — ничего не отправляем.",
        "vote_gone": "Эта отметка уже погасла — спасибо!",
        # --- перевалы (23.5) ---
        "pereval_head": "⛰ Перевалы:",
        "pereval_line": "{name}: {what}",
        "pereval_hazard": "{hazards} до {time}",
        "pereval_calm": "сейчас спокойно",
        "pereval_temp": "{t} °C",
        "pereval_stale": "свежих данных нет",
        "pereval_down": "Данные о погоде на перевалах сейчас недоступны.",
        "btn_pass_sub": "🔔 Предупреждать: {name}",
        "pass_subscribed": ("Готово: напишу, когда на перевале «{name}» появится опасность, и когда "
                            "она уйдёт. Подписки — /my"),
        "pass_alert": "⚠️ {name}: {what}. Осторожно на подъёме.",
        "pass_clear": "✅ {name}: опасность ушла{temp}.",
        # --- город (23.6) ---
        "city_pick": ("Выберите город — пришлю подтверждённые треноги и посты в нём. "
                      "С 7:00 до 23:00, не чаще 6 сообщений в час."),
        "city_subscribed": ("Готово: {city}. Пришлю, когда второй водитель подтвердит треногу или пост. "
                            "Подписки — /my"),
        "city_head": "📍 {city} — подтверждено водителями:",
        "city_line": "{kind} · {where} · {time}\n{link}",
        # --- мои подписки, владелец, отмена (23.7) ---
        "my_head": "Ваши подписки:",
        "my_none": "Подписок нет.",
        "my_family": "👨‍👩‍👧 Близкий водитель — с {date}",
        "my_pass": "⛰ Перевал «{name}»",
        "my_city": "🏙 Город: {city}",
        "btn_remove": "Убрать: {what}",
        "btn_family": "близкий с {date}",
        "removed": "Готово: подписка снята.",
        "remove_missing": "Этой подписки уже нет.",
        "stop_done": "Готово: подписки сняты, больше не пишем.",
        "stop_live": "Трансляция остановлена.",
        "stop_none": "Подписок нет — писать некому.",
        "btn_cancel": "Отменить",
        "cancelled": "Отметка отменена.",
        "cancel_late": "Отменить можно только в первые 2 минуты.",
        "cancel_confirmed": "Отметку уже подтвердил другой водитель — отменить нельзя.",
        "sub_expired": "Подписка «{what}» закончилась: 55 дней не было ваших команд. Продлить — {command}",
    },
    "uz": {
        "start": ("Pastdagi «📍 Joylashuvni yuborish» tugmasi bilan joylashuvni yuboring — yaqinda nima "
                  "borligini koʻrsataman: radarlar, uch oyoqlar, postlar, kameralar va metan. Koʻrganingizni "
                  "oʻsha yerda bitta tugma bilan belgilash mumkin. Barcha buyruqlar — menyuda."),
        "pick": "Bu yerda nima bor?",
        "pick_cng": "Zapravkada vaziyat qanday?",
        "pick_cng_at": "«{name}» zapravkasida vaziyat qanday?",
        "expired": "Nuqta eskirdi — joylashuvni qayta yuboring.",
        "limit": "Bugun uchun belgilar yetarli — rahmat!",
        "slow": "Juda tez-tez — bir-ikki daqiqa kutib, yana bosing.",
        "busy": "Juda tez-tez — hozircha sizdan belgilar yetarli, keyinroq urinib koʻring.",
        "cng_far": "Bazamizda yaqin atrofda metan zapravkasi yoʻq — joylashuvni kolonka yonidan yuboring.",
        "cng_unavailable": "Metan haqidagi belgilar hozir qabul qilinmayapti — keyinroq urinib koʻring.",
        "created": ("Belgilandi ✅ — yaqindagi haydovchilar koʻradi. Ikkinchi haydovchi tasdiqlasa, "
                    "belgi uzoqroq yashaydi."),
        "merged": "Yaqinda allaqachon belgilangan — ovozingiz hisobga olindi.",
        "amended": "Turi aniqlashtirildi.",
        "cng_ok": "Rahmat! Zapravka holati yangilandi.",
        "error": "Yuborib boʻlmadi — birozdan keyin yana urinib koʻring.",
        "kb_location": "📍 Joylashuvni yuborish",
        "kb_metan": "⛽ Yaqindagi metan",
        "help": ("Bot nimalar qila oladi:\n"
                 "📍 Joylashuv — 5 km ichida nima bor: haydovchilar belgilari, statsionar kameralar, "
                 "yopiq yoʻllar, metan. «Koʻrganingizni belgilash» tugmasi — javob ostida.\n"
                 "📡 Joylashuv translyatsiyasi — har daqiqada oldinda yangi nima bor; belgi yonidan "
                 "oʻtsangiz, u hali turibdimi deb soʻrayman.\n"
                 "/metan — yaqindagi AGTKSlar: gaz bormi, navbat.\n"
                 "/pereval — Qamchiq va Taxtaqoracha; ogohlantirishlarga obuna boʻlish mumkin.\n"
                 "/city — shahardagi tasdiqlangan uch oyoqlar va postlar, 7:00 dan 23:00 gacha.\n"
                 "/my — obunalaringiz, /stop — hammasidan obunani bekor qilish.\n"
                 "/lang — til, /privacy — nimalarni saqlaymiz, /app — ilova."),
        "privacy": ("Nimalarni saqlaymiz:\n"
                    "• Telegram-id ochiq holda saqlanmaydi: uning oʻrniga — qaytarib boʻlmaydigan xesh, "
                    "u har 30 kunda almashadi.\n"
                    "• Joylashuv bitta javob uchun kerak va bazaga ham, jurnalga ham yozilmaydi. "
                    "Translyatsiya paytida u faqat xotirada, translyatsiya davom etguncha turadi.\n"
                    "• Shahar va dovonlarga obunalar: chat xeshi, shahar yoki dovon nomi va chat raqami — "
                    "shifrlangan holda. 55 kun buyruqlaringiz boʻlmasa, obuna oʻzi oʻchadi; /stop — "
                    "darhol.\n"
                    "• Belgilar ilovadagidek soatlab yashaydi va ismsiz ketadi.\n"
                    "Batafsil: {url}"),
        "app_soon": ("📱 iPhone uchun RadarMap ilovasi — tez orada App Storeʼda. Unda botda yoʻq narsalar bor: "
                     "rul ortida ovoz, CarPlay va fonda, hatto internetsiz ham kameralar haqida ogohlantirish."),
        "app_link": ("📱 iPhone uchun RadarMap: {url}\nIlovada botda yoʻq narsalar bor: rul ortida ovoz, "
                     "CarPlay va fonda, hatto internetsiz ham kameralar haqida ogohlantirish."),
        "lang_pick": "Tilni tanlang:",
        "lang_set": "Tayyor: oʻzbekcha yozaman.",
        "need_location": "Pastdagi «📍 Joylashuvni yuborish» tugmasi bilan joylashuvni yuboring.",
        "need_location_report": ("Pastdagi «📍 Joylashuvni yuborish» tugmasi bilan joylashuvni yuboring — "
                                 "va u yerda nima borligini tanlang."),
        "off": ("Bu funksiya hozir oʻchirilgan. Radar, uch oyoq yoki postni odatdagidek belgilash mumkin — "
                "joylashuvni yuboring."),
        "unknown_busy": "Hozir boʻlmadi — birozdan keyin urinib koʻring.",
        "near_head": "📍 {radius} radiusda:",
        "near_none": "Haydovchilar belgilari yoʻq.",
        "near_live_down": "Haydovchilar belgilari hozir yuklanmadi — birozdan keyin urinib koʻring.",
        "near_more": "…va yana {n} ta",
        "confirmed": "tasdiqlangan",
        "unconfirmed": "haydovchi belgisi, tasdiqlanmagan",
        "ago_min": "{n} daqiqa oldin",
        "ago_hours": "{h} soat {m} daqiqa oldin",
        "until": "{time} gacha",
        "cameras": "📷 Statsionar kameralar: {n} ta, eng yaqini — {dist}",
        "cameras_none": "📷 Yaqinda statsionar kameralar yoʻq.",
        "cameras_down": "📷 Kameralar bazasi hozir mavjud emas.",
        "speed": "{n} km/soat",
        "metan_line": "⛽ Metan: «{name}» {dist} — {status}",
        "metan_none": "⛽ Radiusda AGTKS yoʻq.",
        "cng_gas": "gaz bor",
        "cng_nogas": "gaz yoʻq",
        "cng_unknown": "maʼlumot yoʻq",
        "cng_queue": "navbat ~{n} daq",
        "btn_mark": "Koʻrganingizni belgilash",
        "btn_further": "Uzoqroq — 15 km",
        "near_slow": "«Yaqinda nima bor»ni 20 soniyada bir marta yangilash mumkin. Bu nuqtani belgilash:",
        "metan_head": "⛽ Eng yaqin AGTKSlar:",
        "metan_empty": "Sizdan 15 km ichida bazamizda AGTKS yoʻq.",
        "metan_down": "AGTKSlar roʻyxati hozir mavjud emas — keyinroq urinib koʻring.",
        "metan_hint": "Holatni zapravka yonida turib belgilash mumkin (300 m gacha).",
        "btn_cng_mark": "Holatni belgilash: {name}",
        "cng_station": "AGTKS",
        "cng_unconfirmed": "tasdiqlanmagan",
        "cng_too_far": "Holatni zapravkaning oʻzida turib belgilash mumkin — joylashuvni oʻsha yerdan yuboring.",
        "live_on": ("📡 Translyatsiya qabul qilindi: har daqiqada yoʻlingizda oldinda yangi nima borligini "
                    "yuboraman. Toʻxtatish — /stop yoki translyatsiyani oʻchiring."),
        "live_ahead": "🚗 Oldinda yoʻlingizda:",
        "live_still": "{kind} hali ham turibdimi?",
        "btn_yes": "Ha",
        "btn_no": "Yoʻq",
        "btn_unseen": "Koʻrmadim",
        "vote_thanks": "Rahmat! Javobni yaqindagi haydovchilar koʻradi.",
        "vote_skip": "Tushunarli — hech narsa yubormaymiz.",
        "vote_gone": "Bu belgi allaqachon oʻchgan — rahmat!",
        "pereval_head": "⛰ Dovonlar:",
        "pereval_line": "{name}: {what}",
        "pereval_hazard": "{time} gacha {hazards}",
        "pereval_calm": "hozir tinch",
        "pereval_temp": "{t} °C",
        "pereval_stale": "yangi maʼlumot yoʻq",
        "pereval_down": "Dovonlardagi ob-havo maʼlumotlari hozir mavjud emas.",
        "btn_pass_sub": "🔔 Ogohlantirish: {name}",
        "pass_subscribed": ("Tayyor: «{name}» dovonida xavf paydo boʻlganda va u ketganda yozaman. "
                            "Obunalar — /my"),
        "pass_alert": "⚠️ {name}: {what}. Koʻtarilishda ehtiyot boʻling.",
        "pass_clear": "✅ {name}: xavf ketdi{temp}.",
        "city_pick": ("Shaharni tanlang — undagi tasdiqlangan uch oyoqlar va postlarni yuboraman. "
                      "7:00 dan 23:00 gacha, soatiga 6 ta xabardan koʻp emas."),
        "city_subscribed": ("Tayyor: {city}. Ikkinchi haydovchi uch oyoq yoki postni tasdiqlaganda yuboraman. "
                            "Obunalar — /my"),
        "city_head": "📍 {city} — haydovchilar tasdiqlagan:",
        "city_line": "{kind} · {where} · {time}\n{link}",
        "my_head": "Obunalaringiz:",
        "my_none": "Obunalar yoʻq.",
        "my_family": "👨‍👩‍👧 Yaqin haydovchi — {date} dan",
        "my_pass": "⛰ «{name}» dovoni",
        "my_city": "🏙 Shahar: {city}",
        "btn_remove": "Olib tashlash: {what}",
        "btn_family": "{date} dagi yaqin",
        "removed": "Tayyor: obuna bekor qilindi.",
        "remove_missing": "Bu obuna allaqachon yoʻq.",
        "stop_done": "Tayyor: obunalar bekor qilindi, endi xabar yubormaymiz.",
        "stop_live": "Translyatsiya toʻxtatildi.",
        "stop_none": "Obunalar yoʻq — xabar yuboradigan hech kim yoʻq.",
        "btn_cancel": "Bekor qilish",
        "cancelled": "Belgi bekor qilindi.",
        "cancel_late": "Faqat dastlabki 2 daqiqada bekor qilish mumkin.",
        "cancel_confirmed": "Belgini boshqa haydovchi tasdiqlagan — bekor qilib boʻlmaydi.",
        "sub_expired": "«{what}» obunasi tugadi: 55 kun buyruqlaringiz boʻlmadi. Uzaytirish — {command}",
    },
}


def lang_of(code):
    """Язык из language_code Telegram — как family_notify.language_of."""
    return "uz" if isinstance(code, str) and code.lower().startswith("uz") else "ru"


def text(lang, key, **values):
    table = TEXTS[lang if lang in TEXTS else "ru"]
    return table[key].format(**values) if values else table[key]


def city_name(city, lang):
    return CITY_NAMES_UZ.get(city, city) if lang == "uz" else city
