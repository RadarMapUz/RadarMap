# App Store — метаданные RadarMap

Переписано 22.10.2026 под сборку 2.2.30 (125). Старая версия (август–октябрь)
устарела: в ней не было «Моей дороги», пробок, близких, расходов, CarPlay на
своей карте. Длины ниже проверены скриптом (`python3` — `len()` по символам,
ключевые слова — ещё и в байтах UTF-8). Поля, которые Apple показывает в
App Store Connect, идут в том же порядке, что и там.

**Чего в текстах нет нарочно** (функция есть в коде, но обещать её нельзя):
хранение поездок в iCloud (выключено до capability в Developer Portal), записанный
узбекский голос (сейчас заготовка — `voice-uz-placeholder`), «Проверить штрафы»
(страницу портала владелец ещё не подтвердил), «№1/лучший/самый точный».

---

## 1. Локализации

| Локализация в ASC | Роль |
|---|---|
| **Russian** | основная для покупателей в Узбекистане |
| **English (U.S.)** | основная (Primary Language) — её читает App Review и видят все прочие витрины |
| **Uzbek** | в списке локализаций App Store Connect узбекского **нет** (на 10.2026 Apple не даёт `uz` как язык метаданных). Узбекские тексты ниже — для сайта soulmed.uz/radarmap, Telegram-канала и пресс-материалов. Если Apple добавит Uzbek — вставить как есть |

Совет: Primary Language = English (U.S.), плюс локализация Russian. Тогда русская
витрина показывает русский текст, а ревьюер — английский.

## 2. Название, подзаголовок, промо-текст

| Поле (лимит) | ru | en | uz (сайт) |
|---|---|---|---|
| Название (30) | `RadarMap — камеры и радары` (26) | `RadarMap: Speed Cameras UZ` (26) | `RadarMap — kamera va radarlar` (29) |
| Подзаголовок (30) | `Антирадар, навигатор, пробки` (28) | `Camera alerts and navigation` (28) | `Antiradar va navigator` (22) |

**Промо-текст (170)** — меняется без новой сборки, можно обновлять к сезону.

- ru (148): `Предупредит о камере заранее — голосом и на экране. Свой навигатор по Узбекистану, «Моя дорога» домой, пробки от водителей, итоги поездок и расходы.`
- en (156): `Hear about every speed camera in time, by voice and on screen. Own navigation for Uzbekistan, your usual road home, live traffic from drivers, trip reports.`
- uz (136): `Kameradan oldindan ogohlantiradi — ovoz va ekranda. Oʻzbekiston boʻylab navigator, uyga «Mening yoʻlim», tirbandlik va safar natijalari.`

## 3. Ключевые слова (100)

Слова из названия и подзаголовка Apple индексирует сама — здесь их не повторяем.
Без пробелов после запятых. Чужие бренды (Яндекс, Waze) не используем —
Guideline 2.3.7.

- ru — 98 символов / 177 байт UTF-8:
  `гаи,дпс,штраф,скорость,лимит,тренога,видеофиксация,ташкент,узбекистан,маршрут,карта,трасса,carplay`
- en — 98 символов (= байт):
  `radar,detector,speedcam,traffic,fines,tashkent,uzbekistan,limit,route,map,police,carplay,gps,drive`
- uz (сайт / на будущее) — 96 символов:
  `kamera,radar,jarima,tezlik,yhxx,toshkent,uzbekistan,xarita,marshrut,tirbandlik,navigator,trenoga`

Про лимит: Apple в справке пишет «100 characters», и поле в ASC считает символы.
Если ASC откажет русской строке по длине (бывало, что поле считало байты), —
запасной вариант ru, 52 символа / 97 байт:
`гаи,дпс,штраф,скорость,лимит,тренога,ташкент,маршрут`

## 4. Описание (4000)

### ru (≈2 780 символов)

```
RadarMap — карта камер видеофиксации Узбекистана и голосовой помощник водителя. 3 600+ стационарных камер и радаров из открытых данных МВД (портал data.egov.uz) хранятся в телефоне, поэтому предупреждения работают и без интернета.

ПРЕДУПРЕЖДАЕТ ВОВРЕМЯ
• Расстояние считается от вашей скорости: на трассе предупреждение приходит раньше, в городе — короче и спокойнее.
• Только камеры на вашей полосе и по курсу — без лишних сигналов на параллельных улицах и развязках.
• Работает со свёрнутым приложением и выключенным экраном, в паре с музыкой и другим навигатором.
• Поездка начинается сама: по движению или только когда телефон подключился к машине (CarPlay или выбранный Bluetooth).
• Камеры, мимо которых вы спокойно ездите каждый день, приложение отмечает галочкой и перестаёт называть вслух.

НАВИГАТОР ПО УЗБЕКИСТАНУ
• Свой движок маршрутов по дорогам Узбекистана, голосовые подсказки, перестроение при съезде.
• Варианты маршрута с числом камер на каждом: «Быстрый», «Меньше камер», «Знакомый».
• «Моя дорога» — дорога домой или на работу, которой вы ездите сами, с вашим обычным временем.
• Подсказки по полосам и ограничение скорости на текущей дороге.
• Пробки — по обезличенным данным водителей RadarMap; предложение объехать, если впереди затор.

ВОДИТЕЛИ ПОМОГАЮТ ДРУГ ДРУГУ
• Кнопка «Радар!» — отметить треногу или пост одним нажатием, не глядя.
• Неподтверждённая отметка показывается пунктиром, подтверждённая другим водителем — сплошной. Устаревшие исчезают сами.
• Места, где треногу ставят часто, отмечены на карте.

ИТОГИ ПОЕЗДОК
• Скорость на каждой камере, рейтинг вождения с разбором по поездкам и камерам.
• Штрафы по действующей шкале в БРВ — сколько удалось не заплатить.
• Дорога на работу и домой: сколько обычно, когда лучше выехать, точный прогноз прибытия.
• Расходы на топливо и зарядку, журнал заправок, расход «бак к баку».

БЛИЗКИЕ ВИДЯТ ПРИБЫТИЕ
• Мама или супруга получают «едет домой, будет примерно в 18:40» по ссылке или в Telegram — только время, без координат.
• Пауза одним нажатием, «я пассажир» — ничего не отправляется.

ЕЩЁ
• CarPlay: своя карта, манёвры, камеры и полосы на экране машины.
• Apple Watch: скорость и вибрация на подходе к камере.
• Виджеты, Live Activity, команды Siri, «Где машина».
• Интерфейс на русском и узбекском, переключается внутри приложения.
• Карта города для работы без сети.

ПРИВАТНОСТЬ
Без регистрации, рекламы и трекеров. Поездки, треки и места дома и работы хранятся на телефоне и на сервер не уходят. Что отправляется — полный список в политике конфиденциальности.

Карта — © OpenMapTiles © участники OpenStreetMap; маршруты и ограничения скорости — © участники OpenStreetMap. Камеры — Портал открытых данных Республики Узбекистан (CC BY-SA 4.0). Лицензии — в приложении: Настройки → О приложении.

RadarMap помогает соблюдать ограничения скорости; соблюдайте ПДД и знаки на дороге.
```

### en (≈2 580 символов)

```
RadarMap is a speed-camera map and voice assistant for drivers in Uzbekistan. 3,600+ fixed cameras and radars from the Ministry of Internal Affairs open dataset (data.egov.uz) are stored on your phone, so alerts keep working without internet.

ALERTS IN TIME
• The warning distance follows your speed: earlier on the highway, short and calm in the city.
• Only cameras on your carriageway and ahead of you — no noise from parallel streets or interchanges.
• Works in the background with the screen off, alongside music or another navigation app.
• Trips start by themselves: from motion, or only when the phone connects to your car (CarPlay or a chosen Bluetooth device).
• Cameras you pass calmly every day get a check mark and are no longer announced.

NAVIGATION FOR UZBEKISTAN
• Own routing engine for Uzbek roads, voice guidance, automatic rerouting.
• Route options with the number of cameras on each: Fastest, Fewer cameras, Familiar.
• My Road — your own usual way home or to work, with your usual travel time.
• Lane guidance and the speed limit of the current road.
• Traffic from anonymous RadarMap driver data, with a detour offer when a jam is ahead.

DRIVERS HELP EACH OTHER
• One "Radar!" button to report a mobile radar or a police post without looking.
• Unconfirmed reports are dashed; confirmed by another driver — solid. Old reports expire on their own.
• Spots where mobile radars appear often are marked on the map.

TRIP REPORTS
• Your speed at every camera, a driving score broken down by trips and cameras.
• Fines at the current official scale — how much you did not have to pay.
• Commute: usual time, best time to leave, an accurate arrival forecast.
• Fuel and charging costs, a fill-up log, real consumption tank to tank.

FAMILY SEES YOUR ARRIVAL
• Family gets "on the way home, about 18:40" by link or in Telegram — time only, no location.
• Pause with one tap; "I'm a passenger" sends nothing.

ALSO
• CarPlay: our own map, maneuvers, cameras and lanes on the car screen.
• Apple Watch: speed and a wrist tap before a camera.
• Widgets, Live Activity, Siri shortcuts, "Where is my car".
• Russian and Uzbek interface, switchable inside the app.
• City map for offline use.

PRIVACY
No sign-up, no ads, no trackers. Trips, tracks, home and work stay on your phone. Everything that is sent is listed in the privacy policy.

Map © OpenMapTiles © OpenStreetMap contributors; routing and speed limits © OpenStreetMap contributors. Cameras: Open Data Portal of the Republic of Uzbekistan (CC BY-SA 4.0). Licenses: in the app, Settings → About.

RadarMap helps you keep to speed limits; always follow traffic rules and road signs.
```

### uz — латиница (сайт, Telegram; ≈3 115 символов)

```
RadarMap — Oʻzbekiston videokuzatuv kameralari xaritasi va haydovchining ovozli yordamchisi. IIV ochiq maʼlumotlaridagi (data.egov.uz portali) 3 600 dan ortiq statsionar kamera va radar telefonda saqlanadi, shuning uchun ogohlantirishlar internetsiz ham ishlaydi.

OʻZ VAQTIDA OGOHLANTIRADI
• Masofa tezligingizga qarab hisoblanadi: trassada ogohlantirish oldinroq, shaharda qisqaroq va xotirjamroq keladi.
• Faqat sizning boʻlagingiz va yoʻnalishingizdagi kameralar — parallel koʻchalar va yoʻl ayrilishlarida ortiqcha signal yoʻq.
• Ilova yigʻilgan va ekran oʻchiq boʻlsa ham ishlaydi, musiqa va boshqa navigator bilan birga.
• Safar oʻzi boshlanadi: harakat boʻyicha yoki faqat telefon mashinaga ulanganda (CarPlay yoki tanlangan Bluetooth).
• Har kuni xotirjam oʻtadigan kameralaringizni ilova belgi bilan ajratadi va ovoz chiqarib aytmaydi.

OʻZBEKISTON BOʻYLAB NAVIGATOR
• Oʻzbekiston yoʻllari boʻyicha oʻz marshrut tizimi, ovozli koʻrsatmalar, yoʻldan chiqsangiz marshrut qayta quriladi.
• Har birida kameralar soni koʻrsatilgan marshrut variantlari: «Tez», «Kamera kamroq», «Tanish».
• «Mening yoʻlim» — uyga yoki ishga oʻzingiz qatnaydigan yoʻl, odatdagi vaqtingiz bilan.
• Boʻlaklar boʻyicha maslahatlar va joriy yoʻldagi tezlik cheklovi.
• Tirbandliklar — RadarMap haydovchilarining anonim maʼlumotlari asosida; oldinda tiqilinch boʻlsa, aylanib oʻtish taklif qilinadi.

HAYDOVCHILAR BIR-BIRIGA YORDAM BERADI
• «Radar!» tugmasi — uch oyoq kamera yoki postni qaramasdan bir bosishda belgilang.
• Tasdiqlanmagan belgi punktir bilan, boshqa haydovchi tasdiqlagani — yaxlit koʻrsatiladi. Eskirganlari oʻzi yoʻqoladi.
• Uch oyoq kamera tez-tez qoʻyiladigan joylar xaritada belgilangan.

SAFAR NATIJALARI
• Har bir kameradagi tezlik, safarlar va kameralar boʻyicha tahlil bilan haydash reytingi.
• Amaldagi BHM shkalasi boʻyicha jarimalar — qancha toʻlamay qolganingiz.
• Ishga va uyga yoʻl: odatda qancha vaqt ketadi, qachon chiqqan maʼqul, aniq yetib kelish vaqti.
• Yoqilgʻi va quvvatlash xarajatlari, yoqilgʻi quyish jurnali, «bakdan bakkacha» sarf.

YAQINLARINGIZ YETIB KELISHINGIZNI KOʻRADI
• Onangiz yoki turmush oʻrtogʻingiz havola yoki Telegram orqali «uyga ketyapti, taxminan 18:40 da yetib keladi» xabarini oladi — faqat vaqt, koordinatasiz.
• Bir bosishda pauza, «Men yoʻlovchiman» — hech narsa yuborilmaydi.

YANA
• CarPlay: mashina ekranida oʻz xaritasi, manevrlar, kameralar va boʻlaklar.
• Apple Watch: kameraga yaqinlashganda tezlik va tebranish.
• Vidjetlar, Live Activity, Siri buyruqlari, «Mashina qayerda».
• Interfeys rus va oʻzbek tillarida, ilova ichida almashtiriladi.
• Internetsiz ishlash uchun shahar xaritasi.

MAXFIYLIK
Roʻyxatdan oʻtish, reklama va kuzatuv yoʻq. Safarlar, treklar, uy va ish joylari telefonda saqlanadi va serverga yuborilmaydi. Nima yuborilishi — maxfiylik siyosatida toʻliq roʻyxat.

Xarita — © OpenMapTiles © OpenStreetMap ishtirokchilari; marshrutlar va tezlik cheklovlari — © OpenStreetMap ishtirokchilari. Kameralar — Oʻzbekiston Respublikasi Ochiq maʼlumotlar portali (CC BY-SA 4.0). Litsenziyalar — ilovada: Sozlamalar → Ilova haqida.

RadarMap tezlik cheklovlariga rioya qilishga yordam beradi; yoʻl harakati qoidalari va yoʻl belgilariga amal qiling.
```

## 5. «Что нового» (4000) — первый публичный выпуск 2.2.30

- ru: `Первый выпуск RadarMap в App Store. Камеры теперь лежат прямо на линии маршрута, новая палитра карты для дня и ночи, плавный наклон карты в поездке, время прибытия с учётом обычных пробок в этот час.`
- en: `First App Store release of RadarMap. Cameras now sit right on the route line, a new day and night map palette, a smooth map tilt while driving, and arrival times that account for usual traffic at that hour.`

(Для первой версии Apple поле «What's New» не показывает; текст пригодится к 2.2.31.)

## 6. Категория, возраст, цена, страны

- Основная категория: **Navigation**. Вторичная: **Travel** (вариант — Utilities; Travel
  выбран потому, что в Узбекистане там меньше конкурентов-антирадаров и туда попадает
  дальняя дорога «Ташкент — Самарканд»).
- Цена: бесплатно, без встроенных покупок, без подписок.
- Страны: минимум **Uzbekistan**; можно все — за пределами Узбекистана приложение
  честно показывает пустую карту без камер, вреда нет.
- Возрастной рейтинг: **4+**. Ответы анкеты (новая анкета Apple 2025 г.):

| Вопрос | Ответ |
|---|---|
| Parental Controls / Age Assurance | No / No |
| Unrestricted Web Access | No (ссылки открываются в Safari, своего браузера нет) |
| User-Generated Content | No — метки радаров состоят только из точки и типа, без текста, фото и общения; отзывы уходят только разработчику |
| Messaging and Chat | No |
| Advertising | No |
| Cartoon/Realistic Violence, Horror, Sexual content, Nudity, Profanity, Mature themes | None |
| Medical/Treatment information, Health and Wellness | None / No |
| Alcohol, Tobacco, Drugs | None |
| Simulated / real gambling, Contests, Loot boxes | None / No |
| Guns / weapons | None |

## 7. URL

Проверено `curl -sI` 22.10.2026 — оба отвечают **200**:

- Support URL: `https://soulmed.uz/radarmap/` (на странице есть «Написать разработчику» — mailto)
- Marketing URL: `https://soulmed.uz/radarmap/`
- Privacy Policy URL: `https://soulmed.uz/radarmap/privacy.html`
  (`/radarmap/privacy` без `.html` — 404, вписывать только с `.html`)

Замечание: на сервере лежит версия privacy.html от 21.10 — без раздела «1а. Ваш
iCloud», который уже есть в `server/privacy.html`. Пока iCloud выключен, это не
ошибка; выложить новую версию **до** включения iCloud.

## 8. Copyright и контакты для ревью

- Copyright: `2026 Zafarbek Polvonboev` (или юрлицо владельца аккаунта)
- App Review Contact: имя, телефон, e-mail владельца (rasul.sadullaev@gmail.com)
- Sign-in required: **No** (аккаунтов нет)

**Чужое в приложении и где это сказано (28.F).** Поле Copyright в ASC — только
владелец; упоминания третьих сторон живут в самом приложении и в описании:
- на карте — «i» в левом нижнем углу и подпись «© OpenMapTiles © OpenStreetMap»
  (тает через 5 с, как разрешают правила OSMF; лицензия OpenMapTiles просит
  подпись в углу карты со ссылками на openmaptiles.org и
  openstreetmap.org/copyright — они в листе «i»);
- Настройки → О приложении → «Источники данных» (по строке на источник со
  ссылкой: OpenMapTiles, OpenStreetMap/ODbL, портал открытых данных/CC BY-SA,
  Open-Meteo/CC BY, стиль OSM Bright) и «Лицензии» — полный английский текст
  MapLibre Native (BSD-2 + уведомления вшитых библиотек: Boost, RapidJSON,
  Metal-cpp, FreeType, HarfBuzz…), OSM Bright (BSD-3, CC BY 4.0), Noto Sans
  (OFL 1.1). BSD требует воспроизвести текст «в документации» бинарной
  поставки — экран «Лицензии» и есть это место.
- В CarPlay — только подпись «© OpenMapTiles © OpenStreetMap» на 5 с: касаний
  в окне машины нет, а лицензии доступны на телефоне.
- Подробно — `server/ATTRIBUTION.md`.

## 9. Заметки для App Review (по-английски, вставить как есть)

```
RadarMap is a driver-assistance and turn-by-turn navigation app for Uzbekistan. No account or sign-in is needed.

LEGALITY OF CAMERA ALERTS
Fixed speed-camera locations come from the official open dataset of the Ministry of Internal Affairs of Uzbekistan, published on the national Open Data Portal: https://data.egov.uz (dataset 1-008-0027, CC BY-SA 4.0). Warning drivers about published enforcement cameras is legal in Uzbekistan, and the app's purpose is to help drivers keep to the speed limit. The app is not a radar detector device and does not interfere with any equipment. Mobile radar markers are reported by drivers, carry no text or photos, and expire automatically.

HOW TO REVIEW OUTSIDE UZBEKISTAN
The camera database and our map tiles cover Uzbekistan only, so outside the country the map around you is empty. To see the app working:
1. Tap "Поиск" (Search) and type "Ташкент" or "Amir Temur" — the map moves to Tashkent with camera markers. Tap any camera marker to open its card (type, address, limit).
2. Tap "Итоги" (Reports) to see the trip reports screen (it is empty until a first trip).
3. Settings ("Ещё" → "Настройки") → "Оповещения" (Alerts) → "Прослушать оповещение" plays the exact voice alert a driver hears before a camera.
4. A screen recording of a real drive in Tashkent (camera alert, route guidance, CarPlay) is attached to this submission.
If you can simulate a location (Xcode → Debug → Simulate Location, or a GPX file) at 41.311, 69.280 (Tashkent), the full experience works: the nearest camera distance appears at the top, routes can be built, and a trip can be started with "Начать поездку".

BACKGROUND LOCATION ("ALWAYS")
Camera alerts must reach the driver while another app (music, another navigator) is on screen or the phone is locked in a car mount. During a trip the app uses continuous location in the background (UIBackgroundModes: location, audio for spoken alerts). Outside a trip it relies on region monitoring and significant-location changes only, around the nearest cameras, to save battery. "While Using" also works; the app explains in onboarding and Settings what "Always" adds. The "fetch" mode refreshes the commute widget before the usual departure.

CARPLAY
The app uses the CarPlay Navigation entitlement (com.apple.developer.carplay-maps): our own map, turn-by-turn maneuvers, lane guidance and camera alerts on the car screen. It can be checked in the iOS Simulator via I/O → External Displays → CarPlay.

DATA
No tracking, no ads, no third-party analytics SDKs. What is sent to our server is listed in the privacy policy and in App Privacy. Trip history stays on the device.
```

Перед отправкой владельцу: **записать и приложить видео** (App Review Information →
Attachment) — 1–2 минуты реальной поездки: предупреждение о камере, ведение по
маршруту, «Радар!», CarPlay в машине. Это самый короткий путь через ревью для
приложения, которое за пределами страны показывает пустую карту. Пункт 3 выше —
строка «Прослушать оповещение» в Настройках → Оповещения; проверить, что путь в
финальной сборке такой.

## 10. App Privacy (анкета Apple)

Сверено 22.10.2026 с `server/privacy.html`, `RadarMap/PrivacyInfo.xcprivacy` и кодом
(`UsageStats`, `TrafficProbes`, `MetricsService`, `FamilyShare`, `EtaShare`,
`FeedbackService`, `MobileCameraService`). **«Data Not Collected» отвечать нельзя.**
Tracking — **No** везде. «Linked to the user» — **No** везде, кроме контакта в форме
обратной связи: аккаунтов нет, идентификатор — случайный UUID, меняется каждые
30 дней; отрезки пробок вообще без идентификатора.

| Тип данных Apple | Собирается? | Linked | Tracking | Цель | Откуда в приложении |
|---|---|---|---|---|---|
| Location → **Precise Location** | Да | No | No | App Functionality | точки «откуда/куда» для маршрута (не хранятся); координата отметки «Радар!»/голоса; отрезки пути для пробок во время поездки (без устройства, без времени суток, без первых/последних 400 м и 300 м у дома/работы; удаляются после расчёта); жалоба «Не предупредила» (место и время проезда) |
| Location → Coarse Location | Нет | | | | |
| Identifiers → **Device ID** | Да | No | No | App Functionality, Analytics | случайный UUID (не IDFA/IDFV), ротация 30 дней — голоса за метки, MetricKit, суточные счётчики |
| Diagnostics → **Crash Data** | Да | No | No | App Functionality | MetricKit на свой сервер, хранится ≤ 30 дней |
| Diagnostics → **Performance Data** | Да | No | No | App Functionality | MetricKit (энергия, зависания) |
| Usage Data → **Product Interaction** | Да | No | No | Analytics | суточные счётчики: поездки, км, оповещения, открытия экранов; модель телефона, версии; уровень разрешения геолокации. Выключается в Настройках |
| User Content → **Customer Support** | Да | No | No | App Functionality | текст в «Написать разработчику» |
| Contact Info → **Other User Contact Info** | Да | **Yes** | No | App Functionality | необязательный контакт для ответа в форме обратной связи |
| Contact Info → **Name** | Да | No | No | App Functionality | «Как вас назовут близким» (до 32 символов) уходит с обновлением «едет домой» — только если пользователь сам включил «Близкие видят прибытие» |
| Other Data → **Other Data Types** | Да | No | No | App Functionality | «Поделиться прибытием» / близкие: время прибытия, оставшееся расстояние, статус «еду/на месте» — без координат и адреса |
| Contacts, Health, Financial, Browsing/Search History, Photos, Audio, Purchases, Sensitive | Нет | | | | номер машины для штрафов хранится только на телефоне; адреса поиска — только на телефоне |

Не считаются «collected» (Apple: данные, недоступные разработчику):
копия поездок в личном iCloud пользователя (приватная база CloudKit; сейчас выключена)
и Telegram-бот (это отдельный сервис, пользователь приложения туда ничего не передаёт;
подписку оформляет получатель).

**Расхождение, которое нужно закрыть до сабмита:** `PrivacyInfo.xcprivacy` объявляет
6 типов, а анкета выше — 8 (добавились Name и Other Data Types от «близких» и
«Поделиться прибытием»). Apple сверяет манифест с анкетой не строго, но правильно —
дописать в манифест `NSPrivacyCollectedDataTypeName` и
`NSPrivacyCollectedDataTypeOtherDataTypes` (Not Linked, App Functionality), а
Device ID — с целью Analytics тоже.

## 11. Скриншоты

`docs/appstore/screenshots/6.9/raw/` — шесть чистых кадров 1320×2868 (iPhone 17 Pro Max,
палитра v5), `docs/appstore/screenshots/6.9/marketing/` — те же кадры с подписью сверху,
1320×2868, PNG без альфы. Порядок, подписи и ключи съёмки — в
`docs/appstore/screenshots/6.9/README.md`. Загружать в ASC **marketing/** в порядке 01→06.

Требования Apple (10.2026): для iPhone обязателен один набор — 6.9″ (1320×2868,
1290×2796 или 1260×2736; 6.5″ 1284×2778/1242×2688 принимается вместо него);
остальные размеры App Store Connect масштабирует сам. От 1 до 10 кадров, PNG/JPEG без
прозрачности. Один набор на локализацию: для English можно загрузить те же кадры
(интерфейс на снимках русский — для витрины Узбекистана это правильно).

**Важно — iPad:** у таргета приложения `TARGETED_DEVICE_FAMILY = "1,2"`, то есть
сборка заявлена и для iPad. Тогда App Store Connect **требует** скриншоты 13″ iPad
(2064×2752 или 2048×2732), а ревьюер проверит приложение на iPad. Решение владельца:
- либо поставить `TARGETED_DEVICE_FAMILY = 1` (только iPhone) до первого релиза —
  после релиза убрать поддержку iPad уже нельзя;
- либо снять отдельный набор iPad.
Рекомендация: только iPhone — CarPlay, режим «в машине» и вертикальная вёрстка
рассчитаны на телефон.

## 12. Что ещё не закрыто (владелец)

- [ ] iPad: решить «только iPhone» или снять iPad-набор (см. §11).
- [ ] CarPlay: убедиться, что грант Navigation есть на App ID (без него строки про CarPlay из описания убрать).
- [ ] Видео поездки для App Review (§9).
- [ ] Манифест приватности: дописать Name и Other Data Types (§10).
- [ ] Copyright и контакт для ревью (§8).
- [ ] Выложить новую privacy.html до включения iCloud (§7).
- [ ] Узбекская локализация — проверить в ASC при создании версии; если её нет, тексты uz — на сайт.
- [ ] Ссылка «Страница проекта» в «О приложении» ведёт на сайт с кнопкой «Поддержать проект»
  (taps.uz). Внутри приложения кнопки оплаты нет, но ревьюер может счесть это призывом
  к оплате в обход IAP (3.1.1). Если спросят — ответить, что это добровольная поддержка
  на сайте, без выгоды в приложении, либо убрать кнопку со страницы на время ревью.
