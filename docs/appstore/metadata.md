# App Store — метаданные RadarMap

## Название (30 симв. макс)
- ru: `RadarMap — камеры и радары`
- uz: `RadarMap — kamera va radarlar`

## Подзаголовок (30 симв. макс)
- ru: `Антирадар и навигатор УЗ`
- uz: `Antiradar va navigator UZ`

## Ключевые слова (100 симв., через запятую, без пробелов)
- ru: `камеры,радар,антирадар,гаи,штраф,скорость,навигатор,ташкент,узбекистан,карта,превышение,лимит`
- uz: `kamera,radar,antiradar,jarima,tezlik,navigator,toshkent,uzbekistan,xarita,yiv,dyhx,speed`

## Описание (ru)

RadarMap — карта камер видеофиксации Узбекистана и голосовой помощник водителя. 3 300+ камер и радаров из официальных открытых данных МВД, обновляются автоматически.

ПРЕДУПРЕЖДЕНИЯ О КАМЕРАХ
• Голос и звук за 22 секунды до камеры — с учётом вашей скорости
• Полноэкранное предупреждение: расстояние, направление, скорость
• Только камеры впереди по курсу — ничего лишнего
• Работает со свёрнутым приложением и погасшим экраном
• Автостарт за рулём: сели в машину — оповещения включились сами

НАВИГАТОР
• Маршруты по Узбекистану (Apple Maps здесь их не строит — у нас свой движок)
• Варианты маршрута с числом камер на каждом — выбирайте, где камер меньше
• Голосовые подсказки: «через 300 метров — направо»
• Автоперестроение при съезде с маршрута
• Дом, Работа и недавние места — маршрут в один тап

ЛИМИТЫ СКОРОСТИ
• Знак ограничения дороги, по которой едете
• Голосовое предупреждение при превышении (допуск настраивается)

ПЕРЕДВИЖНЫЕ РАДАРЫ
• Отмечайте радары на дороге — их увидят все водители
• Подтверждения продлевают метку, устаревшие исчезают сами

ИТОГИ ПОЕЗДОК
• Скорость прохождения каждой камеры
• Дистанция, время, максимальная и средняя скорость, история

БАТАРЕЯ
• Умная геолокация: в тихом режиме расход почти нулевой
• Адаптивный GPS в поездке — точность растёт только возле камер

Без аккаунтов, без рекламы, без сбора личных данных. Данные о камерах — официальный открытый датасет. Карты и лимиты — OpenStreetMap.

## Описание (uz) — кратко

RadarMap — O‘zbekiston videokameralar xaritasi va haydovchining ovozli yordamchisi. 3 300+ kamera va radar rasmiy ochiq ma’lumotlardan, avtomatik yangilanadi.

• Kameraga 22 soniya qolganda ovozli ogohlantirish
• Ekran o‘chiq bo‘lsa ham ishlaydi
• Marshrutlar va ovozli navigatsiya («300 metrdan so‘ng — o‘ngga»)
• Marshrut variantlari — kamerasi kamini tanlang
• Tezlik cheklovlari va oshirishda ogohlantirish
• Ko‘chma radarlarni belgilang — hamma ko‘radi
• Safar natijalari: har bir kameradan o‘tish tezligi
• Batareyani tejaydigan aqlli geolokatsiya

Hisob ochish shart emas, reklama yo‘q, shaxsiy ma’lumotlar yig‘ilmaydi.

## Промо-текст (170 симв.)
- ru: `3300+ камер Узбекистана, голосовой навигатор со своими маршрутами, лимиты скорости и передвижные радары. Работает в фоне, бережёт батарею.`

## App Privacy (анкета Apple)
- Data Not Collected — ДА (мы не собираем данные, связанные с пользователем)
- MetricKit-телеметрия: агрегированные отчёты о крашах/энергии, анонимный UUID,
  не связаны с личностью → по классификации Apple это "Diagnostics → Not linked to you".
  В анкете: Diagnostics (Crash Data, Performance Data) — Not Linked to You, не для трекинга.
- Краудсорсинг радаров: координаты метки + анонимный UUID устройства →
  "Location → Not Linked to You" (отправляется только при ручной отметке радара).
- Геолокация для оповещений обрабатывается только на устройстве.

## Категория
- Основная: Navigation. Вторичная: Utilities.

## Возраст: 4+

## URL
- Privacy Policy: https://soulmed.uz/radarmap/privacy.html
- Support URL: https://soulmed.uz/radarmap/
- Marketing URL: https://soulmed.uz/radarmap/

## Скриншоты (docs/appstore/screenshots/)
- 0_onboarding.png (uz), 1_map.png (uz), 1_map_ru.png, 2_hud_speed.png,
  3_approach.png ★ главный, 4_approach_close.png
- Снято на iPhone 17 Pro Max (6.9", 1320×2868) — формат App Store.
- TODO перед сабмитом: кадры маршрута с вариантами и 3D-поездки (нужны тапы — сниму
  через XCUITest или вручную), тёмная рамка/подписи по вкусу.

## Замечания для ревью Apple
- Приложение показывает ТОЛЬКО стационарные камеры из официального публичного
  госдатасета (data.egov.uz, 1-008-0027) — легально в юрисдикции распространения.
- Передвижные радары — пользовательские метки с TTL 3 часа.
- Фоновая геолокация: режим «Поездка» — оповещения о камерах (UIBackgroundModes
  location+audio), объяснено в onboarding и в purpose strings.

## Замер энергии (15.07.2026)
- Методика: xctrace, шаблон Power Profiler, iPhone 16 Pro (iOS 26.5), 90 с
  активной карты с GPS в foreground (экран включён).
- Результат: средний power impact процесса RadarMap ≈ 0.67 у.е. Apple
  (шкала: <5 — низкий). Трейс: scratchpad/radarmap_power.trace.
- Реальные дорожные цифры (режим поездки, фон) приедут через MetricKit
  с устройств после поездок: смотреть в sqlite на сервере
  (таблица metrics, kind='metric', поле cumulativeCPUTime / displayAPL).
