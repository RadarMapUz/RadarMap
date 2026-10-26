# Полосы в OSM: где их нет у камер (Ташкент)

Собрано 28.09.2026 из свежей выгрузки OSM и базы камер v12. Улиц: 215, мест у камер без полос: 665.
Порядок — по пользе: сколько камер на улице без полос × доля улицы без тега × длина.

## Как править (минута на место)

1. Ссылка открывает редактор iD прямо на месте (нужен вход в аккаунт OSM).
2. Подложка: кнопка слоёв справа → **Bing** или **Esri** (не Google/Яндекс — их снимки обводить запрещено).
3. Кликнуть по проезжей части → «Все теги» → текстом:
   - `lanes=3` — полос в ЭТОМ направлении для односторонней ленты проспекта (раздельные направления нарисованы в OSM двумя линиями);
   - для двусторонней дороги: `lanes=4`, `lanes:forward=2`, `lanes:backward=2`;
   - у стоп-линии перед перекрёстком: `turn:lanes=left|through|through|through;right` (слева направо по ходу).
4. Если полос на участке разное число — разрезать линию (ножницы) в месте смены и проставить каждому куску свои.
5. Сохранить с комментарием «lanes по снимкам Bing».

Наш конвейер забирает OSM раз в неделю (вс) — разметка и стрелки появятся на карте сами.

## 0. Сначала: 20 мест, где число полос спорит со стрелками (26.10.2026)

Здесь в OSM у одной ленты `lanes` говорит одно, а `turn:lanes` — другое (обычно короткий кусок с карманом у перекрёстка). Наш генератор такие ряды стрелок не рисует, чтобы не ставить стрелку на линию. Поправьте так, чтобы число полос в `lanes` совпадало с числом частей в `turn:lanes` (частей = число `|` + 1); если на подходе полос больше из-за кармана — разрежьте линию в месте, где карман начинается, и дайте каждому куску свои `lanes`/`turn:lanes`.

- [ ] 1. [41.31892, 69.27113 (Навои × Рашидов, запад)](https://www.openstreetmap.org/edit?editor=id#map=20/41.31892/69.27113) — разметка 6 полос, `turn:lanes` 5
- [ ] 2. [41.32072, 69.24307](https://www.openstreetmap.org/edit?editor=id#map=20/41.32072/69.24307) — разметка 4 полос, `turn:lanes` 5
- [ ] 3. [41.35977, 69.27700](https://www.openstreetmap.org/edit?editor=id#map=20/41.35977/69.27700) — разметка 5 полос, `turn:lanes` 3
- [ ] 4. [41.31754, 69.25424](https://www.openstreetmap.org/edit?editor=id#map=20/41.31754/69.25424) — разметка 3 полос, `turn:lanes` 5
- [ ] 5. [41.32621, 69.24088](https://www.openstreetmap.org/edit?editor=id#map=20/41.32621/69.24088) — разметка 3 полос, `turn:lanes` 4
- [ ] 6. [41.31133, 69.25247](https://www.openstreetmap.org/edit?editor=id#map=20/41.31133/69.25247) — разметка 4 полос, `turn:lanes` 5
- [ ] 7. [41.31761, 69.31707](https://www.openstreetmap.org/edit?editor=id#map=20/41.31761/69.31707) — разметка 4 полос, `turn:lanes` 3
- [ ] 8. [41.34892, 69.28723](https://www.openstreetmap.org/edit?editor=id#map=20/41.34892/69.28723) — разметка 3 полос, `turn:lanes` 4
- [ ] 9. [41.36000, 69.33727](https://www.openstreetmap.org/edit?editor=id#map=20/41.36000/69.33727) — разметка 3 полос, `turn:lanes` 5
- [ ] 10. [41.31734, 69.28121](https://www.openstreetmap.org/edit?editor=id#map=20/41.31734/69.28121) — разметка 3 полос, `turn:lanes` 5
- [ ] 11. [41.31098, 69.34576](https://www.openstreetmap.org/edit?editor=id#map=20/41.31098/69.34576) — разметка 3 полос, `turn:lanes` 4
- [ ] 12. [41.35498, 69.37587](https://www.openstreetmap.org/edit?editor=id#map=20/41.35498/69.37587) — разметка 5 полос, `turn:lanes` 4
- [ ] 13. [41.29622, 69.26852](https://www.openstreetmap.org/edit?editor=id#map=20/41.29622/69.26852) — разметка 4 полос, `turn:lanes` 3
- [ ] 14. [41.31768, 69.29449](https://www.openstreetmap.org/edit?editor=id#map=20/41.31768/69.29449) — разметка 4 полос, `turn:lanes` 5
- [ ] 15. [41.32089, 69.30216](https://www.openstreetmap.org/edit?editor=id#map=20/41.32089/69.30216) — разметка 3 полос, `turn:lanes` 5
- [ ] 16. [41.32103, 69.30405](https://www.openstreetmap.org/edit?editor=id#map=20/41.32103/69.30405) — разметка 3 полос, `turn:lanes` 4
- [ ] 17. [41.32555, 69.19338](https://www.openstreetmap.org/edit?editor=id#map=20/41.32555/69.19338) — разметка 3 полос, `turn:lanes` 4
- [ ] 18. [41.31112, 69.25820](https://www.openstreetmap.org/edit?editor=id#map=20/41.31112/69.25820) — разметка 5 полос, `turn:lanes` 3
- [ ] 19. [41.32641, 69.22958](https://www.openstreetmap.org/edit?editor=id#map=20/41.32641/69.22958) — разметка 5 полос, `turn:lanes` 4
- [ ] 20. [41.31201, 69.28122](https://www.openstreetmap.org/edit?editor=id#map=20/41.31201/69.28122) — разметка 3 полос, `turn:lanes` 5

Источник: аудит дорог `docs/roads_audit_2026-10-23.md`, приложение А. После правки и ближайшей пересборки тайлов ряды стрелок появятся сами.

## 1. Kichik Halqa yo'li — магистраль, 65.0 км, без полос 57%, камер без полос: 51

- [ ] камера 2144: [Kxay, piyodalar yo'lakchasi (Korzinka Kohinur)](https://www.openstreetmap.org/edit?editor=id#map=19/41.28028/69.19552)
- [ ] камера 2603: [Kxay - Farxod avtomobil Extiyot Qismlari bozori Qarshisiga](https://www.openstreetmap.org/edit?editor=id#map=19/41.28237/69.19456)
- [ ] камера 2139: [Kxay Farxod Zapchast bozori Avtoturargoxga Kirish Oldiga](https://www.openstreetmap.org/edit?editor=id#map=19/41.28341/69.19429)
- [ ] камера 2085: [Algoritm Guliston-kovunchi chorrahasi (Asab va Ruhiyat) oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.28437/69.19464)
- [ ] камера 2604: [Kxay -To‘xtagul Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.28671/69.19456)
- [ ] камера 2648: [Janubiy Vokzal (Ko‘prik)](https://www.openstreetmap.org/edit?editor=id#map=19/41.26188/69.22425)
- …ещё 45 мест на этой улице

## 2. Toshkent halqa avtomobil yo'li — магистраль, 64.2 км, без полос 74%, камер без полос: 36

- [ ] камера 2818: [Txay "Asr Gullari" Do‘koni Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.39830/69.23773)
- [ ] камера 2082: [Abu Saxiy masjidi, Txay](https://www.openstreetmap.org/edit?editor=id#map=19/41.24876/69.16467)
- [ ] камера 2171: [Txay "Abu Saxiy" Bo‘ta Buva Masjid oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.24852/69.16468)
- [ ] камера 2174: [Txay "Abu Saxiy" bozori qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.24568/69.16562)
- [ ] камера 2124: [D001 avtomobil Yo‘lining 0 km “Сhinni bozor” oldi 2](https://www.openstreetmap.org/edit?editor=id#map=19/41.24083/69.16690)
- [ ] камера 3529: [Txay - Chinobod - Tong Nuri Koʻchalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36927/69.32466)
- …ещё 30 мест на этой улице

## 3. Xonobodtepa shoh ko'chasi — магистраль, 33.6 км, без полос 63%, камер без полос: 18

- [ ] камера 2070: [Txay ko‘chasi "Artel" zavodi qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.26470/69.36459)
- [ ] камера 2071: [Qo‘yliq Ota masjidi, Qo‘yliq Ota 1-TOR ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.23777/69.32224)
- [ ] камера 2510: [D001 Toshkеnt Xalqa avtomobil Yuli 3/21-UY qarshisida (Dadax](https://www.openstreetmap.org/edit?editor=id#map=19/41.24456/69.27747)
- [ ] камера 2205: [D001 Toshkеnt Halqa avtomobil yo‘li, 1-UY qarshisida (Korzin](https://www.openstreetmap.org/edit?editor=id#map=19/41.24432/69.31038)
- [ ] камера 2517: [D001 Txay avtomobil Yo‘lining 55 km. Da](https://www.openstreetmap.org/edit?editor=id#map=19/41.24421/69.28956)
- [ ] камера 2063: [Qo‘yliq Dehqon bozori oldi (Tunel oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.23756/69.32980)
- …ещё 12 мест на этой улице

## 4. Kukcha Darvoza ko'chasi — проспект, 15.0 км, без полос 65%, камер без полос: 13

- [ ] камера 3532: [kichik Xalqa Yoʻli, Koʻkcha Darvoza 492-UY oldidagi piyodala](https://www.openstreetmap.org/edit?editor=id#map=19/41.31843/69.19337)
- [ ] камера 2466: [Ko‘kcha Darvoza ko‘chasi, 411-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.31887/69.19635)
- [ ] камера 2602: [Ko‘kcha Darvoza ko‘chasi, 650-UY (Uyg‘ur-zulfizor Ko‘chalari](https://www.openstreetmap.org/edit?editor=id#map=19/41.30516/69.15781)
- [ ] камера 2599: [Ko‘kcha Darvoza - Zulfizar chorrahasi 581-UY Burchagi (Taqac](https://www.openstreetmap.org/edit?editor=id#map=19/41.30512/69.15792)
- [ ] камера 2597: [Ko'kcha Darvoza ko‘chasi, 548-UY (Zakovat ko‘chasi bilan Cho](https://www.openstreetmap.org/edit?editor=id#map=19/41.31471/69.18665)
- [ ] камера 2601: [Ko‘kcha Darvoza ko‘chasi, 499-UY (Xondamir ko‘chasi bilan Ch](https://www.openstreetmap.org/edit?editor=id#map=19/41.31103/69.17599)
- …ещё 7 мест на этой улице

## 5. Amir Temur shoh ko'chasi — проспект, 20.8 км, без полос 47%, камер без полос: 14

- [ ] камера 2244: [Turkiston va Amir Tеmur Shox ko‘chasi Chorraxasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29403/69.28902)
- [ ] камера 2202: [Amir Tеmur ko‘chasi Aviakassa oldi 53 Uy oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29506/69.28806)
- [ ] камера 2201: [Amir Temur Shoh ko'chasi, 51 ("Temiryo'lchilar" Saroyi oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.29613/69.28665)
- [ ] камера 2203: [Amir Tеmur ko‘chasi Markaziy Aviakassa 51 Uy oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29614/69.28684)
- [ ] камера 2784: [Amir Temur ko‘chasi 41-UY 271-MAKTAB oldi Yo‘layriq mfy](https://www.openstreetmap.org/edit?editor=id#map=19/41.37651/69.28825)
- [ ] камера 2783: [Amir Temur ko‘chasi (Yunusobod Krugi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.36706/69.28512)
- …ещё 8 мест на этой улице

## 6. Ahmad Donish ko'chasi — проспект, 21.4 км, без полос 55%, камер без полос: 10

- [ ] камера 2780: [Ahmad Donish ko‘chasi, 32-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35222/69.26569)
- [ ] камера 2773: [A.temir - A.donish ko'chalari kesishmasi Ko'prik Krug tomon](https://www.openstreetmap.org/edit?editor=id#map=19/41.36429/69.28761)
- [ ] камера 2774: [A.temur - A.donish Ko‘chalari kesishmasi (Ko‘prik)](https://www.openstreetmap.org/edit?editor=id#map=19/41.36395/69.28762)
- [ ] камера 2839: [Yunusobod Dеhqon bozori qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.36489/69.28872)
- [ ] камера 2769: [A.donish - Usta Shirin Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34916/69.26294)
- [ ] камера 2771: [A.donish-yangi shahar Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36657/69.29216)
- …ещё 4 мест на этой улице

## 7. Farg'ona Yo'li — проспект, 19.1 км, без полос 42%, камер без полос: 14

- [ ] камера 2054: [Bektemir yo'li Ikkita Ko'prik Oralig'iga](https://www.openstreetmap.org/edit?editor=id#map=19/41.23603/69.33215)
- [ ] камера 2064: [Qo‘yliq Most Usti Bektemir Postga Qarab Ketish - 1](https://www.openstreetmap.org/edit?editor=id#map=19/41.23599/69.33206)
- [ ] камера 2062: [Qo‘yliq Dehqon bozori Yon Tomoni (Ko‘prik Yon Qismi 1)](https://www.openstreetmap.org/edit?editor=id#map=19/41.23703/69.33120)
- [ ] камера 2209: [Farg‘ona yo‘li ko‘chasi Ulfat Do‘koni qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.26520/69.31508)
- [ ] камера 2728: [Farg‘ona yo‘li ko‘chasi 217-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.26582/69.31524)
- [ ] камера 2727: [Farg‘ona yo‘li ko‘chasi 217-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.26581/69.31472)
- …ещё 8 мест на этой улице

## 8. Yangi Sergeli ko'chasi — проспект, 8.2 км, без полос 92%, камер без полос: 9

- [ ] камера 2561: [yangi Sirg‘ali ko‘chasi, 8-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.22558/69.22070)
- [ ] камера 2562: [yangi Sirg‘ali va Navruz Ko‘chalari Chorraxasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.24857/69.21785)
- [ ] камера 2509: [Choshtеpa va yangi Sеrgеli Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25327/69.21691)
- [ ] камера 2558: [yangi Sirg‘ali ko‘chasi D001 Txay Ko‘prigi Tagida](https://www.openstreetmap.org/edit?editor=id#map=19/41.24134/69.21657)
- [ ] камера 2560: [yangi Sirg‘ali ko‘chasi, 21A-UY qarshisida (Asia.uz Supеrmar](https://www.openstreetmap.org/edit?editor=id#map=19/41.22201/69.22274)
- [ ] камера 2556: [yangi Sergeli ko‘chasi, 46-UY oldidagi piyodalar o'tish joyi](https://www.openstreetmap.org/edit?editor=id#map=19/41.23538/69.21442)
- …ещё 3 мест на этой улице

## 9. Choshtepa ko'chasi — проспект, 10.7 км, без полос 100%, камер без полос: 7

- [ ] камера 2505: [Choshtеpa ko‘chasi 140-UY ("Samo" To‘yxonasi qarshisida) qar](https://www.openstreetmap.org/edit?editor=id#map=19/41.24470/69.20232)
- [ ] камера 2508: [Choshtеpa ko‘chasi 80-UY qarshisida (Choshtеpa Choyxonasi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.24835/69.20920)
- [ ] камера 2507: [Choshtеpa ko‘chasi 328-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.23127/69.18488)
- [ ] камера 2506: [Choshtеpa ko‘chasi 272-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.23641/69.18895)
- [ ] камера 2697: [Choshtepa ko‘chasi (Choshtepa bekati oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.23976/69.19537)
- [ ] камера 2509: [Choshtеpa va yangi Sеrgеli Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25327/69.21691)
- …ещё 1 мест на этой улице

## 10. Gavxar ko'chasi — проспект, 7.0 км, без полос 89%, камер без полос: 9

- [ ] камера 2132: [Gavhar ko‘chasi, "Olmazor" Mеtro Bеkati qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.25430/69.19537)
- [ ] камера 2134: [Gavhar ko‘chasi, "Olmazor" Mеtro Bеkati qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.25441/69.19675)
- [ ] камера 3523: [Shota Rustaveli va Gavhar Ko‘chalari kesishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25901/69.21909)
- [ ] камера 2133: [Gavhar ko‘chasi, "Olmazor" Mеtro Bеkati qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.25439/69.19784)
- [ ] камера 2135: [Gavxar ko‘chasi, 122A-UY oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25432/69.20164)
- [ ] камера 2664: [Sh. Rustaveli - Gavhar Ko`chalari kesishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25801/69.21691)
- …ещё 3 мест на этой улице

## 11. Katta Xirmontepa koʻchasi — улица 2-го класса, 7.9 км, без полос 66%, камер без полос: 10

- [ ] камера 2635: [katta Xirmontеpa va Shirin Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.28516/69.17085)
- [ ] камера 2609: [Lutfiy - katta Xirmontepa chorrahasi 2-UY Qarshisi (Vatan ch](https://www.openstreetmap.org/edit?editor=id#map=19/41.27649/69.17275)
- [ ] камера 2636: [katta Xirmontеpa-lutfiy Ko‘chalari Chorraxasida (Vatan Kinot](https://www.openstreetmap.org/edit?editor=id#map=19/41.27677/69.17229)
- [ ] камера 2634: [katta Xirmontepa ko'chasi, 10A-UY oldidagi piyodalar o'tish ](https://www.openstreetmap.org/edit?editor=id#map=19/41.27264/69.17609)
- [ ] камера 2181: [Xirmontеpa-zargarlik Ko‘chalari Chorraxhasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27147/69.17728)
- [ ] камера 2190: [katta Xirmontеpa ko‘chasi 48-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.26788/69.18222)
- …ещё 4 мест на этой улице

## 12. Qamarniso ko'chasi — улица 2-го класса, 5.0 км, без полос 100%, камер без полос: 8

- [ ] камера 2375: [Qamarniso va Nozimaxonim Ko‘chalari Kesishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35874/69.19383)
- [ ] камера 2376: [Qamarniso va Nozimaxonim Ko‘chalari Kesishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35893/69.19355)
- [ ] камера 2377: [Qamarniso va Nozimaxonim Ko‘chalari Kesishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35909/69.19333)
- [ ] камера 2327: [D001 Txay ko‘chasi, Gilam Saroy To‘yxonasi qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.36489/69.18065)
- [ ] камера 2326: [D001 Txay ko‘chasi, Gilam Saroy To‘yxonasi qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.36475/69.18019)
- [ ] камера 2378: [Qamarniso – Shifokorlar Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36289/69.18793)
- …ещё 2 мест на этой улице

## 13. Farobiy ko'chasi — проспект, 13.2 км, без полос 54%, камер без полос: 9

- [ ] камера 2424: [Txay – Farobiy Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34828/69.16537)
- [ ] камера 2336: [Farobiy va Mirzo G‘olib Ko‘chalari Tutashuvi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34820/69.19802)
- [ ] камера 2419: [To‘lqin Akrom masjidi, Farobiy ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.35013/69.18805)
- [ ] камера 2337: [Farobiy va Shifokor Ko‘chalari Chorraxasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34942/69.17863)
- [ ] камера 2332: [Farobiy ko‘chasi "Onkologiya" markazi qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.34692/69.20115)
- [ ] камера 2459: [Farobiy ko‘chasi. (Beruniy metro)](https://www.openstreetmap.org/edit?editor=id#map=19/41.34555/69.20534)
- …ещё 3 мест на этой улице

## 14. Qumariq ko'chasi — проспект, 11.1 км, без полос 80%, камер без полос: 6

- [ ] камера 2549: [Sodiq Tolipov va Qumariq Ko‘chalari Kеsishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.26979/69.27613)
- [ ] камера 2532: [Oltin Vodiy mfy Qumariq ko‘chasi 17 Uy 237-MAKTAB oldida](https://www.openstreetmap.org/edit?editor=id#map=19/41.25986/69.25504)
- [ ] камера 2540: [Qumariq ko'chasi 2-UY oldi (Toshshaharnur Binosi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.26369/69.25806)
- [ ] камера 2545: [Qumariq ko‘chasi, 20-UY Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25096/69.25461)
- [ ] камера 2546: [Qumariq va D001 Thay chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.24461/69.25630)
- [ ] камера 2539: [Qumariq - Xonabodtepa Shox Ko‘chalari chorrahasi (Yo‘l O‘rta](https://www.openstreetmap.org/edit?editor=id#map=19/41.24443/69.25629)

## 15. Bunyodkor shoh koʻchasi (dublyor) — улица 3-го класса, 18.9 км, без полос 38%, камер без полос: 10

- [ ] камера 2100: [Bunyodkor Shoh ko‘chasi, Avtovokzal qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.25763/69.19412)
- [ ] камера 2099: [Bunyodkor Shoh ko‘chasi, Avtovokzal qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.25681/69.19306)
- [ ] камера 2096: [Bunyodkor Shoh ko‘chasi Sovplastital zavodi Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25970/69.19621)
- [ ] камера 2097: [Bunyodkor Shoh ko‘chasi Sovplastital zavodi Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25966/69.19619)
- [ ] камера 2101: [Bunyodkor Shox Koʻchasi 57-UY "Fiber Side-plast" Mchj Binosi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25022/69.18279)
- [ ] камера 2089: [Bunyodkor Shoh ko‘chasi (Ipodrom Ro‘parasi Ko‘p Qavvatli Sto](https://www.openstreetmap.org/edit?editor=id#map=19/41.24294/69.17205)
- …ещё 4 мест на этой улице

## 16. Yangi Yunusobod ko'chasi — улица 2-го класса, 4.9 км, без полос 79%, камер без полос: 9

- [ ] камера 2842: [yangi Yunusobod Chayka Ro‘parasi Siti Burger](https://www.openstreetmap.org/edit?editor=id#map=19/41.37197/69.31711)
- [ ] камера 2847: [yangi shahar - yangi Yunusobod ko'chalari kesishmasi chorrah](https://www.openstreetmap.org/edit?editor=id#map=19/41.36323/69.29826)
- [ ] камера 2841: [yangi Yunusobod Anjir Milliy Taomlar](https://www.openstreetmap.org/edit?editor=id#map=19/41.36710/69.30240)
- [ ] камера 2844: [yangi Yunusobod Koʻchasi "Carbon Car Wash" Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36715/69.30248)
- [ ] камера 2843: [yangi Yunusobod Koʻchasi "Carbon Car Wash" Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36718/69.30299)
- [ ] камера 3530: [Txay - yangi Yunusobod - Iqbol Koʻchalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.37345/69.32272)
- …ещё 3 мест на этой улице

## 17. Talabalar ko'chasi — улица 2-го класса, 4.3 км, без полос 100%, камер без полос: 7

- [ ] камера 2373: [QORAQAMISH-2 va QORAQAMISH-4 Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36405/69.20394)
- [ ] камера 2417: [Talabalar – Qamarniso Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.35775/69.20639)
- [ ] камера 2418: [Talabalar – Ziyo Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.35457/69.20941)
- [ ] камера 2416: [Talabalar va Universitet Koʼchalari Kesishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35119/69.21272)
- [ ] камера 2415: [Talabalar va Universitet Koʼchalari Kesishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35086/69.21303)
- [ ] камера 2414: [Talabalar va Universitet Koʼchalari Kesishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35075/69.21297)
- …ещё 1 мест на этой улице

## 18. Abdurauf Fitrat ko'chasi — улица 2-го класса, 5.3 км, без полос 98%, камер без полос: 6

- [ ] камера 2232: [Sarakulsk - Fitrat Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.26841/69.29634)
- [ ] камера 2228: [Qorasuv A.fitrat 83-A 154-MAKTAB oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27015/69.30168)
- [ ] камера 2233: [Sarakulskaya - Fitrat (Bеxtеrеva - Fitrat) chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27049/69.30295)
- [ ] камера 2198: [A.fitrat - 35 Uy va 2-PROYEZD Oltinko‘l Ko‘chalari qarshisid](https://www.openstreetmap.org/edit?editor=id#map=19/41.27171/69.30644)
- [ ] камера 2207: [Fargʼona Yoʼli va M.аshrafi Koʼchalari Chorrahasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.27307/69.31064)
- [ ] камера 2214: [Farg‘ona yo‘li- M.ashrafi Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27308/69.31063)

## 19. Beshqayrog`och ko`chasi — улица 2-го класса, 4.5 км, без полос 100%, камер без полос: 6

- [ ] камера 2570: [Beshqayrag‘och, Bekobod va Xamkor Ko‘chalari kesishmasi 106 ](https://www.openstreetmap.org/edit?editor=id#map=19/41.32174/69.17869)
- [ ] камера 2572: [Bеshqayrag‘och (Ziyo Said) ko‘chasi 109-UY qarshisida (Hamko](https://www.openstreetmap.org/edit?editor=id#map=19/41.32148/69.17883)
- [ ] камера 2622: [To‘qimachi-beshqayrag‘och ko‘chasi, 290A-228 Uylar oldi (9-S](https://www.openstreetmap.org/edit?editor=id#map=19/41.31398/69.15895)
- [ ] камера 2571: [Beshqayrog‘och mfy, Ziyo Said ko‘chasi 28-UY 116-MAKTAB oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.31546/69.16295)
- [ ] камера 2573: [Bеshqayrag‘och ko‘chasi, 250-UY qarshisida (116-MAKTAB)](https://www.openstreetmap.org/edit?editor=id#map=19/41.31569/69.16354)
- [ ] камера 2576: [D001 Txay 9,6-KM (18-AVTOSTANSIYA)](https://www.openstreetmap.org/edit?editor=id#map=19/41.31553/69.15487)

## 20. Zargarlik ko'chasi — улица 2-го класса, 6.1 км, без полос 100%, камер без полос: 5

- [ ] камера 2167: [So'g'ali Ota-zargarlik Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27386/69.18761)
- [ ] камера 2184: [Zargarlik ko‘chasi, 41/1-UY Burchagi (Makaronka)](https://www.openstreetmap.org/edit?editor=id#map=19/41.27269/69.18271)
- [ ] камера 2181: [Xirmontеpa-zargarlik Ko‘chalari Chorraxhasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27147/69.17728)
- [ ] камера 2183: [Zargarlik ko‘chasi "Ikki Do‘st" Kafesi oldida](https://www.openstreetmap.org/edit?editor=id#map=19/41.25981/69.16179)
- [ ] камера 2170: [Tkad-agrosanoat Kolleji (Prokuratura)](https://www.openstreetmap.org/edit?editor=id#map=19/41.25516/69.15671)

## 21. Abdulla Qodiriy ko'chasi — проспект, 14.8 км, без полос 42%, камер без полос: 8

- [ ] камера 2388: [Qorasaroy va Abdulla Qodiriy Ko‘chalari chorrahasi (Abdulla ](https://www.openstreetmap.org/edit?editor=id#map=19/41.33080/69.24284)
- [ ] камера 2443: [Abdulla Qodiriy - Abay Ko‘chalari kesishmasi (O‘zbekiston Da](https://www.openstreetmap.org/edit?editor=id#map=19/41.32475/69.25496)
- [ ] камера 2445: [Abdulla Qodiriy ko‘chasi, 11-UY qarshisida (Islom Akadеmiyas](https://www.openstreetmap.org/edit?editor=id#map=19/41.32494/69.25682)
- [ ] камера 2813: [Oloy bozori Tor ko‘chasi, 64-UY oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.32099/69.28376)
- [ ] камера 2812: [Oloy bozori Tor Ko’cha (62 Uy oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.32091/69.28483)
- [ ] камера 2439: [A.qodiriy ko‘chasi (Ganga Avtobus bekati oldi piyodalar O‘ti](https://www.openstreetmap.org/edit?editor=id#map=19/41.32805/69.24838)
- …ещё 2 мест на этой улице

## 22. Qorasaroy ko'chasi — улица 2-го класса, 8.3 км, без полос 71%, камер без полос: 6

- [ ] камера 2390: [Qorasaroy – yangi Olmazor Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.35119/69.24205)
- [ ] камера 2389: [Qorasaroy – Nurafshon chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34177/69.24196)
- [ ] камера 2387: [Qorasaroy ko‘chasi 341-UY qarshisida (Usta Shirin ko‘chasi b](https://www.openstreetmap.org/edit?editor=id#map=19/41.35723/69.24253)
- [ ] камера 2391: [Qorasaroy – № 28 maktab Qarashisda](https://www.openstreetmap.org/edit?editor=id#map=19/41.34449/69.24160)
- [ ] камера 2392: [Qorasaroy-changalzor Mavzuk Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36520/69.24074)
- [ ] камера 2388: [Qorasaroy va Abdulla Qodiriy Ko‘chalari chorrahasi (Abdulla ](https://www.openstreetmap.org/edit?editor=id#map=19/41.33080/69.24284)

## 23. Nurafshon aylanma ko'chasi — проспект, 18.7 км, без полос 37%, камер без полос: 8

- [ ] камера 2367: [Nurafshon ko‘chasi 20-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.34170/69.23651)
- [ ] камера 2471: [Nurafshon va Labzak Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.33451/69.26445)
- [ ] камера 2463: [Kox Ota masjidi, Kox Ota ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.33677/69.25950)
- [ ] камера 2368: [Nurafshon ko‘chasi 20-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.34187/69.23753)
- [ ] камера 2389: [Qorasaroy – Nurafshon chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34177/69.24196)
- [ ] камера 2473: [Nurafshon va Xumdonsoy Ko‘chalari Chorrahasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.30494/69.20814)
- …ещё 2 мест на этой улице

## 24. Sag’bon ko’chasi — проспект, 7.5 км, без полос 63%, камер без полос: 7

- [ ] камера 2394: [Sag'bon ko‘chasi № 11-MAKTAB qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.33960/69.23179)
- [ ] камера 2401: [Sag‘bon – Nurafshon Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34113/69.23105)
- [ ] камера 2396: [Sag'bon – Shoshiy (Kushtut) Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.33736/69.23300)
- [ ] камера 2399: [Sag‘bon ko‘chasi, 123-UY (24-MAKTAB) qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.33580/69.23371)
- [ ] камера 2344: [Islomobod masjidi, Sag‘bon ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34736/69.22804)
- [ ] камера 2395: [Sag'bon – Sag'bon 30-BЕRK Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34491/69.22919)
- …ещё 1 мест на этой улице

## 25. So'galli ota ko'chasi — улица 2-го класса, 7.5 км, без полос 100%, камер без полос: 4

- [ ] камера 2083: [Al Xorazmiy-so'gali Ota Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25991/69.18815)
- [ ] камера 2136: [Guliston-sugalli Ota Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.26551/69.16035)
- [ ] камера 2169: [So‘galli Ota va Diydor Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.26048/69.17334)
- [ ] камера 2166: [Shayx Muxammad Sodiq Muxammad Yusuf masjidi, So‘galli Ota ko](https://www.openstreetmap.org/edit?editor=id#map=19/41.25965/69.18615)

## 26. Ohangaron yoʻli — магистраль, 20.3 км, без полос 30%, камер без полос: 9

- [ ] камера 2752: [Ohangaron Shox ko‘chasi "Azs" Ayoqsh qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.27285/69.36217)
- [ ] камера 2753: [Ohangaron Shox ko‘chasi "Sеul" Kafеsi qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.28069/69.36131)
- [ ] камера 2722: [D001 "Toshkent Xalqa avtomobil yo'li" avtomobil yo'lining 44](https://www.openstreetmap.org/edit?editor=id#map=19/41.28585/69.36025)
- [ ] камера 2747: [Ohangaron Shoh ko‘chasi, Tuzel 2-MAVZE 22B-UY Qarshisidagi p](https://www.openstreetmap.org/edit?editor=id#map=19/41.28852/69.35948)
- [ ] камера 2059: [Ohangaron Shox - X.bayqaro Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25782/69.37923)
- [ ] камера 2756: [Oxongaron yo‘li Krestik Chorraxa (Gumma Xona) oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29341/69.35597)
- …ещё 3 мест на этой улице

## 27. Usta Shirin ko'chasi — улица 2-го класса, 4.9 км, без полос 100%, камер без полос: 5

- [ ] камера 2387: [Qorasaroy ko‘chasi 341-UY qarshisida (Usta Shirin ko‘chasi b](https://www.openstreetmap.org/edit?editor=id#map=19/41.35723/69.24253)
- [ ] камера 2832: [Usta Shirin - Bog‘iravon Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34665/69.26734)
- [ ] камера 2430: [Usta Shirin – Taxtapul Darvoza Ko‘chalari Chorrahasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.34750/69.26596)
- [ ] камера 2769: [A.donish - Usta Shirin Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34916/69.26294)
- [ ] камера 2429: [Usta Shirin – Shirok Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.35615/69.24796)

## 28. Aviasozlar ko'chasi — улица 2-го класса, 3.5 км, без полос 100%, камер без полос: 6

- [ ] камера 2718: [Aviasozlar-qorasuv Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29215/69.33981)
- [ ] камера 2716: [Aviasozlar ko‘chasi 2-UY qarshisida (Avtostansiya qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.28183/69.35031)
- [ ] камера 2717: [Aviasozlar-bеshariq Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.28624/69.34645)
- [ ] камера 2736: [Kadisheva Aviasozlar bozori oldidagi Avtobus bekati](https://www.openstreetmap.org/edit?editor=id#map=19/41.28636/69.34617)
- [ ] камера 2738: [Kadishеva ko‘chasi Abtobus Bеkati](https://www.openstreetmap.org/edit?editor=id#map=19/41.28622/69.34672)
- [ ] камера 2737: [Kadisheva Beshariq va Aviasozlar Chorraxasi 45 Uy Yon Qismi](https://www.openstreetmap.org/edit?editor=id#map=19/41.28577/69.34702)

## 29. Buyuk Ipak yo'li ko'chasi — улица 2-го класса, 14.4 км, без полос 66%, камер без полос: 4

- [ ] камера 2300: [Sh.burxanov - Buyuk Ipak yo‘li Ko‘chalari chorrahasi 22 Uy B](https://www.openstreetmap.org/edit?editor=id#map=19/41.33738/69.35564)
- [ ] камера 2303: [To‘ra Buvi masjidi, Parkent yo‘li ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.35037/69.37715)
- [ ] камера 2255: [Buyuk Ipak yo‘li - Gulirayxon Ko‘chalari Kеsishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35000/69.37440)
- [ ] камера 2257: [Buyuk Ipak yo‘li ko‘chasi 395-UY oldi (Avtoshkola Ttz)](https://www.openstreetmap.org/edit?editor=id#map=19/41.34824/69.36716)

## 30. Universitet ko'chasi — улица 2-го класса, 3.1 км, без полос 100%, камер без полос: 6

- [ ] камера 3128: [10V09 avtomobil Yo‘lining, Univеrsitеt Ko‘chasi-salar ko‘cha](https://www.openstreetmap.org/edit?editor=id#map=19/41.38212/69.35403)
- [ ] камера 3126: [10V09 "Toshkеnt Sh.- O‘nqo‘rg‘on Q.-yonariq Q.-M-39 Avtoyo‘l](https://www.openstreetmap.org/edit?editor=id#map=19/41.36538/69.34096)
- [ ] камера 3123: [10B09- Toshkеnt-o‘nqo‘rg‘on Q.-yonariq Q.- M-39 Avtoyo‘li (8](https://www.openstreetmap.org/edit?editor=id#map=19/41.36895/69.34443)
- [ ] камера 3125: [10V09 "Toshkеnt Sh.- O‘nqo‘rg‘on Q.-yonariq Q.-M-39 Avtoyo‘l](https://www.openstreetmap.org/edit?editor=id#map=19/41.37175/69.34660)
- [ ] камера 3127: [10V09 "Toshkеnt Sh.- O‘nqo‘rg‘on Q.-yonariq Q.-M-39 Avtoyo‘l](https://www.openstreetmap.org/edit?editor=id#map=19/41.37734/69.34998)
- [ ] камера 2828: [Txay-bog‘ishamol Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.35969/69.33780)

## 31. Bektemir yo'li ko'chasi — магистраль, 5.0 км, без полос 100%, камер без полос: 4

- [ ] камера 2054: [Bektemir yo'li Ikkita Ko'prik Oralig'iga](https://www.openstreetmap.org/edit?editor=id#map=19/41.23603/69.33215)
- [ ] камера 2064: [Qo‘yliq Most Usti Bektemir Postga Qarab Ketish - 1](https://www.openstreetmap.org/edit?editor=id#map=19/41.23599/69.33206)
- [ ] камера 2055: [Bektemir-xusain Boyqaro-oltin Topgan Chorraxasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.23284/69.33486)
- [ ] камера 2078: [Xuton masjidi, Bektemir yo‘li ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.22861/69.33586)

## 32. Chingiz Aytmatov ko'chasi — улица 2-го класса, 4.1 км, без полос 100%, камер без полос: 4

- [ ] камера 2788: [Bog'ishamol - Chingiz Aytmatov Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34020/69.29348)
- [ ] камера 2810: [Mirzo Yusuf masjidi, Bog‘ishamol ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34020/69.29341)
- [ ] камера 2801: [Chingiz Aytmatov-osiyo Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.32694/69.29108)
- [ ] камера 2800: [Chingiz Aytmatov - Shivli Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.33556/69.29259)

## 33. Sariko'l ko'chasi — улица 2-го класса, 2.9 км, без полос 98%, камер без полос: 5

- [ ] камера 2222: [Istiqlolobod mfy Sarakul ko‘chasi 9A Uy 57-MAKTAB oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27820/69.28625)
- [ ] камера 2204: [Banakotiy - Sarakulsk Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27731/69.28772)
- [ ] камера 2240: [St.sarakulskaya - Talimarjon (Bеxtеrеva - Manjara) chorrahas](https://www.openstreetmap.org/edit?editor=id#map=19/41.27259/69.29458)
- [ ] камера 2232: [Sarakulsk - Fitrat Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.26841/69.29634)
- [ ] камера 3521: [kichik Halqa yo'li - Avliyo Ota - Sariko'l ko'chalari kesish](https://www.openstreetmap.org/edit?editor=id#map=19/41.28907/69.28229)

## 34. Samarqand Darvoza koʻchasi — улица 2-го класса, 4.3 км, без полос 93%, камер без полос: 4

- [ ] камера 2484: [Samarqand Darvozasi ko‘chasi Rovd Ro‘parasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.30396/69.21411)
- [ ] камера 2481: [Samarqand Darvoza – Rasulova Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.30969/69.22184)
- [ ] камера 2482: [Samarqand Darvoza – Tеrmiz Tor Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.30978/69.22173)
- [ ] камера 2489: [Zangi Ota masjidi, Samarqand Darvoza ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.31347/69.22608)

## 35. Yangishahar ko‘chasi — проспект, 6.1 км, без полос 48%, камер без полос: 7

- [ ] камера 2836: [Yangishahar-chinabod chorrahasi (“Ht Mall City” Ro‘parasi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.35600/69.30976)
- [ ] камера 2846: [yangi shahar - Chinobod ko'chalari](https://www.openstreetmap.org/edit?editor=id#map=19/41.35606/69.30967)
- [ ] камера 2848: [yangi shahar ko‘chasi (Universam Dehqon bozori, Avtoturargoh](https://www.openstreetmap.org/edit?editor=id#map=19/41.36640/69.29279)
- [ ] камера 2834: [Yangishahar ko‘chasi 1-UY (“Texnomart” Do‘koni Avtoturargoh ](https://www.openstreetmap.org/edit?editor=id#map=19/41.36543/69.29440)
- [ ] камера 2847: [yangi shahar - yangi Yunusobod ko'chalari kesishmasi chorrah](https://www.openstreetmap.org/edit?editor=id#map=19/41.36323/69.29826)
- [ ] камера 2837: [Yangishahar-yunusabod chorrahasi (5-BOLALAR shifoxonasi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.36285/69.29865)
- …ещё 1 мест на этой улице

## 36. Qoraqamish 3-ko'chasi — улица 2-го класса, 3.0 км, без полос 100%, камер без полос: 4

- [ ] камера 2323: [Chimqo‘rg‘on - 3 Chi Qoraqamish Ko‘chalari (Ashb) Avtobus be](https://www.openstreetmap.org/edit?editor=id#map=19/41.37054/69.20513)
- [ ] камера 2372: [QORAQAMISH-1-QORAQAMI-3 va Ostana Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.37041/69.21480)
- [ ] камера 2428: [Umid mfy A.yunusov ko‘chasi 21-UY 219-MAKTAB oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.37041/69.21819)
- [ ] камера 2379: [Qoraqamish -3 ko‘chasi № 242– maktab qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.37043/69.21062)

## 37. Qorasuv ko'chasi — улица 2-го класса, 4.1 км, без полос 100%, камер без полос: 3

- [ ] камера 2718: [Aviasozlar-qorasuv Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29215/69.33981)
- [ ] камера 2759: [Qorasuv ko‘chasi 4-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.29387/69.34052)
- [ ] камера 2758: [Qorasuv ko‘chasi 13-UY qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.29075/69.33930)

## 38. Mehrigiyo ko'chasi — улица 2-го класса, 4.0 км, без полос 100%, камер без полос: 3

- [ ] камера 2528: [Mehrigiyo ko‘chasi (Sergeli Dehqon bozori oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.22664/69.21885)
- [ ] камера 2529: [Mеxrigiyo ko‘chasi (Habibiy mahallasi) Arka oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.22424/69.21273)
- [ ] камера 2709: [yangi Umid mfy, Mehrigiyo ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.22035/69.20297)

## 39. Qoraqamish ko'chasi — улица 2-го класса, 3.8 км, без полос 100%, камер без полос: 3

- [ ] камера 2400: [Sag‘bon va Qoraqamish Ko‘chalari Chorrahasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35565/69.22640)
- [ ] камера 2380: [Qoraqamish -№ 326 maktab qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35586/69.21836)
- [ ] камера 2384: [Qoraqamish ko‘chasi "Qariyalar" Pansionati qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35720/69.21597)

## 40. Nugʻmonov koʻchasi — улица 2-го класса, 2.3 км, без полос 100%, камер без полос: 4

- [ ] камера 3245: [Eshonguzar Qo‘rg‘oni X.no‘mon ko‘chasi (Prokuratura Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25451/69.15581)
- [ ] камера 3246: [Eshonguzar Qo‘rg‘oni X.no‘mon va Mustaqillik Shox Ko‘chalari](https://www.openstreetmap.org/edit?editor=id#map=19/41.25195/69.15428)
- [ ] камера 3257: [Mustaqillik va X.nugmon ko'chalari](https://www.openstreetmap.org/edit?editor=id#map=19/41.25198/69.15411)
- [ ] камера 2170: [Tkad-agrosanoat Kolleji (Prokuratura)](https://www.openstreetmap.org/edit?editor=id#map=19/41.25516/69.15671)

## 41. Beruniy shoh ko'chasi — проспект, 7.9 км, без полос 38%, камер без полос: 6

- [ ] камера 2330: [Farobi va Bеruniy Shox Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34522/69.20705)
- [ ] камера 2501: [Кхай - Беруний (Орзу Чорраҳаси) Кўчаси](https://www.openstreetmap.org/edit?editor=id#map=19/41.33900/69.20719)
- [ ] камера 2451: [Bеruniy Shox ko‘chasi 1B-UY qarshisida (Bog‘ko‘cha ko‘chasi ](https://www.openstreetmap.org/edit?editor=id#map=19/41.33054/69.22237)
- [ ] камера 2448: [Beruniy ko‘chasi 6-UY Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.32765/69.22716)
- [ ] камера 2500: [Беруний Ва Сақчимон Кўчалар Кесишмаси](https://www.openstreetmap.org/edit?editor=id#map=19/41.32509/69.23168)
- [ ] камера 2447: [Beruniy ko‘chasi (G‘uncha Kinoteatri)](https://www.openstreetmap.org/edit?editor=id#map=19/41.33080/69.22162)

## 42. Al-Xorazmiy ko'chasi — улица 2-го класса, 3.6 км, без полос 100%, камер без полос: 3

- [ ] камера 2083: [Al Xorazmiy-so'gali Ota Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25991/69.18815)
- [ ] камера 2180: [Xirmontеpa-al Xorazmiy Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.26472/69.18875)
- [ ] камера 2084: [Al-xorazimiy ko‘chasi (Ubay Ibn Ka’b masjidi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.26430/69.18861)

## 43. Qatortol ko'chasi — улица 2-го класса, 6.0 км, без полос 62%, камер без полос: 4

- [ ] камера 2143: [Kxay va Qatortol ko'chalari kesishgan chorraha](https://www.openstreetmap.org/edit?editor=id#map=19/41.27872/69.19804)
- [ ] камера 2158: [Qatortol - Cho‘ponota chorrahasi (“Rayhon” Milliy Taomlar Ro](https://www.openstreetmap.org/edit?editor=id#map=19/41.28625/69.20539)
- [ ] камера 2162: [Qatortol ko‘chasi, Nomdor Kafe 12 Uy Oldiga](https://www.openstreetmap.org/edit?editor=id#map=19/41.28046/69.19975)
- [ ] камера 2152: [Muqumiy ko‘chasi (Sport Buyumlari oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.29652/69.21612)

## 44. Shahrisabz ko'chasi — проспект, 6.5 км, без полос 58%, камер без полос: 4

- [ ] камера 2237: [Shaxrisabz ko'chasi Avtobus bekati oldi (Qqb Ro'parasi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.30321/69.27959)
- [ ] камера 2239: [Shaxrisabz ko‘chasi Milliy Teleradiokompaniya oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.30831/69.28555)
- [ ] камера 2236: [Shahrisabz ko‘chasi 3-UY Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29960/69.27445)
- [ ] камера 2238: [Shaxrisabz ko‘chasi "O‘zdonmaxsulot" Binosi qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.30455/69.28167)

## 45. Chilonzor ko'chasi — улица 2-го класса, 6.4 км, без полос 73%, камер без полос: 3

- [ ] камера 2114: [Chilonzor Torgoviy Sentr Avtoturargox Kirish oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.28273/69.22309)
- [ ] камера 2119: [Chilonzor-gagarin ko‘chasi (Targoviy Sentr Osh markazi oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.28404/69.22464)
- [ ] камера 2188: [katta Qozirobod masjidi, Chilonzor Shox ko‘chasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27710/69.21576)

## 46. Yangi Qo'yliq ko'chasi — улица 2-го класса, 6.5 км, без полос 94%, камер без полос: 2

- [ ] камера 2248: [yangi Qo'yliq Bozori-kim Pеn Xva Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.24923/69.30160)
- [ ] камера 2246: [Txay - yangi Qo‘yliq Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.24510/69.30156)

## 47. Ziyolilar ko'chasi — улица 2-го класса, 5.1 км, без полос 59%, камер без полос: 4

- [ ] камера 2311: [Ziyolilar ko‘chasi "Ibr" Ayoqsh qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.33575/69.31617)
- [ ] камера 2312: [Ziyolilar ko‘chasi "Lux Auto Motors" qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.33561/69.31579)
- [ ] камера 2313: [Ziyolilar va Qalandar Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.33752/69.33034)
- [ ] камера 2266: [Dor‘mon yo‘li, Ziyolilar, Mo‘minov Ko‘chalari kesishmasi (It](https://www.openstreetmap.org/edit?editor=id#map=19/41.34045/69.33564)

## 48. Uch Qahramon ko'chasi — улица 2-го класса, 2.5 км, без полос 100%, камер без полос: 3

- [ ] камера 2829: [Uch Qaxromon ko‘chasi 9 Dahasi Avtobus bekati](https://www.openstreetmap.org/edit?editor=id#map=19/41.37246/69.27582)
- [ ] камера 2830: [Uch Qaxromon ko‘chasi 9 Dahasi Sqb (Sanoat Qurilish Bank) Ol](https://www.openstreetmap.org/edit?editor=id#map=19/41.37663/69.28184)
- [ ] камера 2831: [Uch Qаxromon Koʼchаsi 9 Dаhаsi Аvtobus Shox Bekаti Oldigа](https://www.openstreetmap.org/edit?editor=id#map=19/41.37829/69.28247)

## 49. Qoraqamish 4-ko'chasi — улица 2-го класса, 1.5 км, без полос 100%, камер без полос: 4

- [ ] камера 2373: [QORAQAMISH-2 va QORAQAMISH-4 Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36405/69.20394)
- [ ] камера 2382: [Qoraqamish 4 ko‘chasi (Tansiqboy bozor Ro‘parasi Avtobus bek](https://www.openstreetmap.org/edit?editor=id#map=19/41.36722/69.20458)
- [ ] камера 2323: [Chimqo‘rg‘on - 3 Chi Qoraqamish Ko‘chalari (Ashb) Avtobus be](https://www.openstreetmap.org/edit?editor=id#map=19/41.37054/69.20513)
- [ ] камера 2383: [Qoraqamish 4 – QORAQAMISH-3 Ko‘chalari Kеsishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.37005/69.20508)

## 50. Geydar Aliev ko'chasi — улица 2-го класса, 4.0 км, без полос 100%, камер без полос: 2

- [ ] камера 2220: [Gaydar Aliyev ko‘chasi (Transport Instituti oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.27351/69.27790)
- [ ] камера 2221: [Gеydar Aliyev ko‘chasi, 305-UY qarshisida (Lokomotiv va Abdu](https://www.openstreetmap.org/edit?editor=id#map=19/41.27200/69.27939)

## 51. Shirin ko'chasi — улица 2-го класса, 4.4 км, без полос 56%, камер без полос: 4

- [ ] камера 2616: [Shirin –Foziltеpa Ko‘chalari Chorrahasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.28516/69.16531)
- [ ] камера 2613: [Lutfiy va Shirin Ko‘chalari Chorrahasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.28169/69.18074)
- [ ] камера 2167: [So'g'ali Ota-zargarlik Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.27386/69.18761)
- [ ] камера 2635: [katta Xirmontеpa va Shirin Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.28516/69.17085)

## 52. Shota Rustaveli ko'chasi — проспект, 13.8 км, без полос 14%, камер без полос: 10

- [ ] камера 3501: [Shota Rustaveli ko‘chasi, Janubiy Vokzal oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25917/69.22253)
- [ ] камера 2668: [Sh.rustaveli-bobur Koʼchalari kesishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.28520/69.25359)
- [ ] камера 2676: [Shota Rustaveli ko'chasi (Frunzenskiy Ts)](https://www.openstreetmap.org/edit?editor=id#map=19/41.28568/69.25379)
- [ ] камера 3523: [Shota Rustaveli va Gavhar Ko‘chalari kesishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25901/69.21909)
- [ ] камера 2678: [Shota Rustaveli ko'chasi, Vega Sentr oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.25959/69.22434)
- [ ] камера 2669: [Sh.rustavelli-choʼpon Ota Koʼchalari kesishmasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.26813/69.23439)
- …ещё 4 мест на этой улице

## 53. Doʻmbirobod koʻchasi — улица 2-го класса, 3.7 км, без полос 100%, камер без полос: 2

- [ ] камера 2125: [Do`mbirobod ko`chasi 132-UY Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.26062/69.20555)
- [ ] камера 2126: [Dumbrobod ko‘chasi Avtobus bekati 75,77,79 Uylar oldi (Orien](https://www.openstreetmap.org/edit?editor=id#map=19/41.26414/69.20742)

## 54. Sergeli yo‘li shoh ko‘chasi — проспект, 11.1 км, без полос 87%, камер без полос: 1

- [ ] камера 2520: [Fayzli Toshkеnt ko‘chasi “Xсmg” Sеrvis Mchj Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.22685/69.24313)

## 55. Turkiston ko'chasi — проспект, 0.9 км, без полос 100%, камер без полос: 5

- [ ] камера 2241: [Turkiston ko‘chasi, 10-UY qarshisida (T.shеvchеnko ko‘chasi ](https://www.openstreetmap.org/edit?editor=id#map=19/41.29233/69.28603)
- [ ] камера 2245: [Turkiston-oybеk Ko‘chalari chorrahasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29129/69.28434)
- [ ] камера 2243: [Turkiston ko‘chasi, Shimoliy Vokzal qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.29320/69.28765)
- [ ] камера 2244: [Turkiston va Amir Tеmur Shox ko‘chasi Chorraxasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.29403/69.28902)
- [ ] камера 2242: [Turkiston ko‘chasi, Shimoliy Vokzal qarshisida](https://www.openstreetmap.org/edit?editor=id#map=19/41.29245/69.28622)

## 56. Qipchoq ko'chasi — проспект, 8.1 км, без полос 100%, камер без полос: 1

- [ ] камера 2510: [D001 Toshkеnt Xalqa avtomobil Yuli 3/21-UY qarshisida (Dadax](https://www.openstreetmap.org/edit?editor=id#map=19/41.24456/69.27747)

## 57. Zangiota ko'chasi — улица 2-го класса, 3.6 км, без полос 100%, камер без полос: 2

- [ ] камера 2490: [Zangiota va Jarariq Ko‘chalari chorrahasi (Korzinka qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.33560/69.17504)
- [ ] камера 2487: [Txay "Xankar Sound Avto Moyka" Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.33680/69.16423)

## 58. Shimoliy Olmazor ko'chasi — улица 2-го класса, 3.4 км, без полос 100%, камер без полос: 2

- [ ] камера 2410: [Shimoliy Olmazor – yangi Olmazar Ko‘chalari Kеsishmasida](https://www.openstreetmap.org/edit?editor=id#map=19/41.35037/69.25245)
- [ ] камера 2349: [Kxay - Shimoliy Olmazor Ko‘chalari Chorraxasi](https://www.openstreetmap.org/edit?editor=id#map=19/41.34817/69.25205)

## 59. Moyqoʻrgʻon koʻchasi — улица 2-го класса, 3.3 км, без полос 100%, камер без полос: 2

- [ ] камера 2811: [Moyqo‘rg‘on ko‘chasi, 62A-UY Qarshisi](https://www.openstreetmap.org/edit?editor=id#map=19/41.36082/69.27737)
- [ ] камера 2786: [Axmad Donish - Moyqo‘rg‘on chorrahasi (Shoxsaroy bekat oldi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.36015/69.27787)

## 60. Yunusota koʻchasi — улица 2-го класса, 4.3 км, без полос 53%, камер без полос: 4

- [ ] камера 2838: [Yunus Ota va Ibragimov ko'chalari](https://www.openstreetmap.org/edit?editor=id#map=19/41.37417/69.30571)
- [ ] камера 2849: [Янги Юнусобод - Юнусота Кўчалари Чорраҳаси](https://www.openstreetmap.org/edit?editor=id#map=19/41.36983/69.31142)
- [ ] камера 2765: ["Sayram" Chorrahasidagi Kafelar oldi](https://www.openstreetmap.org/edit?editor=id#map=19/41.37011/69.31185)
- [ ] камера 2840: [Yunusota ko‘chasi (Mediapark Qarshisi)](https://www.openstreetmap.org/edit?editor=id#map=19/41.37029/69.31113)
