# Переезд на домен + HTTPS

Зачем: HTTP на голый IP читается любым Wi-Fi по дороге (локации водителей),
а App Review заворачивает `NSAllowsArbitraryLoads`. Подпись OTA (Ed25519)
уже защищает базу камер, пульт и правки даже на HTTP, но трафик локаций
закрывает только TLS.

**Это единственный жёсткий блокер публикации.** И он же держит панель
модератора на SSH-туннеле: basic auth по открытому HTTP — это пароль
администратора, отданный любому Wi-Fi по дороге.

## Что уже готово (проверено 7 августа 2026)

- **certbot установлен** (`/usr/bin/certbot`) — ставить ничего не надо;
- в `nginx-radarmap.conf` заготовлен закомментированный блок `location /admin/`
  с basic auth: раскомментировать сразу после выпуска сертификата;
- на VPS есть чужие сайты (Dentalor), поэтому certbot запускаем **только**
  с явным `-d <домен>`, чтобы он не трогал соседние конфиги.

Осталось ровно одно: **купить домен**.

## Шаги (на VPS, после покупки домена)

1. A-запись домена → 45.130.148.94; подождать резолва (`dig +short домен`).
2. В `/etc/nginx/conf.d/radarmap.conf` вписать `server_name домен;`
   и применить: `nginx -t && systemctl reload nginx`.
3. Выпустить сертификат:
   ```
   certbot --nginx -d домен --redirect
   ```
   Автопродление certbot ставит сам (systemd timer). Проверить:
   `systemctl list-timers | grep certbot`.
4. Раскомментировать `location /admin/` и завести файл паролей:
   ```
   printf 'admin:' >> /etc/nginx/.radarmap_admin
   openssl passwd -apr1 >> /etc/nginx/.radarmap_admin
   chmod 640 /etc/nginx/.radarmap_admin && chown root:www-data /etc/nginx/.radarmap_admin
   nginx -t && systemctl reload nginx
   ```
5. Сказать Клоду домен — в приложении меняется одна строка
   (`AppConfig.syncBaseURL`) и удаляется `NSAllowsArbitraryLoads` из
   `Info.plist`; опционально добавляется пиннинг ключа сертификата.
6. Обновить ссылку на политику конфиденциальности в App Store Connect:
   сейчас она на голом IP, а Apple такое не любит.

## Что уже защищено без HTTPS

- OTA-база камер, пульт и правки модератора: Ed25519-подпись, `fail closed`
  (`SignedPayload`), проверка ДО разбора JSON.
- API: суточные капы per-device (`api.py`) + per-IP rate-limit (nginx).
  IP берётся из заголовка, который nginx **перезаписывает** сам, — иначе
  клиент подставлял туда что угодно (закрыто 7 августа).
- Приватность: device-UUID ротируется раз в 30 дней; суточная статистика
  использования не содержит координат.
- Панель модератора наружу не выставлена вовсе.
