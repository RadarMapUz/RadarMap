# Фразы голоса — для записи узбекского диктора

Собрано 13.10.2026 из кода, который говорит (камеры, манёвры, лимиты, пробки, отметки).
`%@`, `%lld` — подставляемые слова и числа: диктору нужно записать числа 1–20, десятки, сотни, «метр», «метров»,
«километр», типы камер и стороны отдельно; склейка — в приложении (пункт 3.1 плана прода).

Всего шаблонов: 104

> 21.10.2026 (этап 16): диктору отдаётся не этот файл, а сценарий
> `tools/voice_kit/script_uz.csv` — 142 отрывка, выведенных из кода (см.
> `tools/voice_kit/README.md`). Таблицу ниже не править: VoiceComposerTests
> разбирает её и требует, чтобы каждая звучащая фраза собиралась из отрывков
> целиком, а каждая незвучащая была названа (только экран, имя собственное,
> убрана из приложения).

| Русский | O‘zbekcha |
|---|---|
|  на %@ |  — %@ tomon |
| %@ %@, %lld метров | %@ %@, %lld metr |
| %@, %lld метров | %@, %lld metr |
| +%@ из-за пробок | tirbandlik tufayli +%@ |
| , здесь %lld | , bu yerda %lld |
| , через %@ | , %@ orqali |
| . Ваша скорость %lld | . Tezligingiz %lld |
| . Ваша скорость %lld, лимит %lld | . Tezligingiz %lld, cheklov %lld |
| Быстрее на %@ | %@ tezroq |
| Впереди пробка. Есть путь быстрее на %@ | Oldinda tirbandlik. %@ tezroq yo‘l bor |
| Впереди пробка: около %1$@, плюс %2$@ | Oldinda tirbandlik: taxminan %1$@, qo‘shimcha %2$@ |
| Выезд на встречную полосу | Qarama-qarshi yo'nalishga chiqish |
| ДТП | YTH |
| Дорожные знаки и разметка | Yo'l belgilari va chiziqlar |
| Ждём спутники | Sun'iy yo'ldoshlarni kutmoqdamiz |
| Заезд за стоп-линию | Stop chizig'idan o'tib ketish |
| Здесь часто ставят треногу | Bu yerda tez-tez uchoyoq qo‘yiladi |
| Здесь часто ставят треногу, %@ | Bu yerda tez-tez uchoyoq qo‘yiladi, %@ |
| Из двух левых рядов | Chapdagi ikki qatordan |
| Из двух правых рядов | O‘ngdagi ikki qatordan |
| Из левого ряда | Chap qatordan |
| Из левых рядов | Chap qatorlardan |
| Из любого ряда, кроме левого | Chapdan boshqa istalgan qatordan |
| Из любого ряда, кроме правого | O‘ngdan boshqa istalgan qatordan |
| Из правого ряда | O‘ng qatordan |
| Из правых рядов | O‘ng qatorlardan |
| Из среднего ряда | O‘rta qatordan |
| Из средних рядов | O‘rta qatorlardan |
| Из трёх левых рядов | Chapdagi uch qatordan |
| Из трёх правых рядов | O‘ngdagi uch qatordan |
| Интеллектуальная камера + радар | Intellektual kamera + radar |
| Камера | Kamera |
| Камеры впереди, %lld метров | Oldinda kameralar, %lld metr |
| Маршрут не найден | Marshrut topilmadi |
| Маршрут не построился | Yo‘nalish tuzilmadi |
| Маршрута уже нет — заезд не добавлен | Marshrut endi yo‘q — kirib o‘tish qo‘shilmadi |
| Маршруты временно недоступны — мы уже чиним | Marshrutlar vaqtincha ishlamayapti — tuzatyapmiz |
| Нарушение правил остановки | To'xtash qoidalarini buzish |
| Нарушение правил стоянки | To'xtab turish qoidalarini buzish |
| Не видим вашего положения — маршрут не построен | Joylashuvingizni koʻrmayapmiz — marshrut tuzilmadi |
| Не вижу точного положения — маршрут пока не построить | Aniq joylashuv yo‘q — hozircha yo‘nalish tuzib bo‘lmaydi |
| Не удалось заехать по пути — маршрут прежний | Yo‘l-yo‘lakay kirib o‘tib bo‘lmadi — marshrut avvalgidek |
| Нет связи | Aloqa yo‘q |
| Нет связи с сервером маршрутов — проверьте интернет | Marshrut serveri bilan aloqa yo‘q — internetni tekshiring |
| Нет связи, отправлю позже | Aloqa yo‘q, keyinroq yuboraman |
| Объезд пробки | Tirbandlikni aylanib o‘tish |
| Объезд пробки · через %@ | Tirbandlikni aylanib o‘tish · %@ orqali |
| Ограничение %1$lld через %2$@ | %2$@ dan so‘ng tezlik cheklovi %1$lld |
| Отметка водителей: %@ | Haydovchilar belgisi: %@ |
| Отметка ставится в движении | Belgi harakat paytida qo'yiladi |
| Отметки сейчас выключены | Belgilar hozir o‘chirilgan |
| Отмечали %lld раз, в разные дни: %lld | %lld marta belgilangan, turli kunlarda: %lld |
| Отмечен водителями, исчезнет ~%@ | Haydovchilar belgilagan, ~%@ da yo'qoladi |
| Передвижной радар | Ko'chma radar |
| По маршруту %@ через %lld метров | Marshrutda %@ %lld metrdan so‘ng |
| Подтвердили, спасибо | Tasdiqlandi, rahmat |
| Пост ДПС | YPX posti |
| Превышение скорости | Tezlik oshirildi |
| Принято, спасибо | Qabul qilindi, rahmat |
| Проезд на красный | Qizil chiroqda o'tish |
| Радар | Radar |
| Ремень безопасности | Xavfsizlik kamari |
| Сервер не отвечает | Server javob bermayapti |
| Сервер отклонил отметку | Server belgini rad etdi |
| Слишком часто, подождите минуту | Juda tez-tez, bir daqiqa kuting |
| Стационарная камера | Statsionar kamera |
| Стационарный радар | Statsionar radar |
| Странный ответ сервера | Serverdan g‘alati javob |
| Тип уточнён | Turi aniqlashtirildi |
| Тренога | Uch oyoq kamera |
| Уже отметили здесь | Bu yerda allaqachon belgilangan |
| Через %lld метров — %@ | %lld metrdan so‘ng — %@ |
| без пробок | tirbandliksiz |
| впереди | oldinda |
| впереди слева | oldinda chapda |
| впереди справа | oldinda o‘ngda |
| вы прибыли | yetib keldingiz |
| держитесь левее | chap tomonda yuring |
| держитесь правее | o‘ng tomonda yuring |
| до ДТП | YTHgacha |
| до камеры | kameragacha |
| до передв. радара | ko'chma radargacha |
| до поста ДПС | YPX postigacha |
| до радара | radargacha |
| до точки | nuqtagacha |
| до треноги | uch oyoq kameragacha |
| заезд: %@ | kirib o‘tish: %@ |
| круто налево | keskin chapga buriling |
| круто направо | keskin o‘ngga buriling |
| на кольце %lld-й съезд | aylanada %lld-chiqish |
| обычно %@ | odatda %@ |
| обычно вечером | odatda kechqurun |
| обычно днём | odatda kunduzi |
| обычно ночью | odatda kechasi |
| обычно утром | odatda ertalab |
| перестройтесь в поток | oqimga qo‘shiling |
| плавно левее | biroz chapga oling |
| плавно правее | biroz o‘ngga oling |
| по вашим поездкам | safarlaringiz bo‘yicha |
| поверните налево | chapga buriling |
| поверните направо | o‘ngga buriling |
| разворот | orqaga buriling |
| сверните на съезд | chiqish yo‘liga buriling |
| съезд на развязку | yo‘l ayirmasiga chiqing |

## Дорога на работу — «призрак» (этап 8, 19.10)

Время подставляется числом («9:12»); минуты — с формой числа (ru: минуту/минуты/минут).

| Русский | Узбекский (черновик, проверить носителю) |
|---|---|
| На работу к %@ | Ishga %@ da |
| Домой к %@ | Uyga %@ da |
| как обычно | odatdagidek |
| на %lld минуту / минуты / минут дольше обычного | odatdagidan %lld daqiqa uzoqroq |
| с запасом %lld минуту / минуты / минут | %lld daqiqa zaxira bilan |
| впритык | vaqt zo‘rg‘a yetadi |
| на %lld минуту / минуты / минут позже срока | muddatdan %lld daqiqa kech |

Со сроком «быть к 9:00» (8.8.5) хвост фразы — запас вместо «как обычно»:
«На работу к 8:51, с запасом 9 минут». Позже срока — один раз за поездку,
снова только если стало хуже ещё на 5 минут; «поторопитесь» не звучит никогда.
