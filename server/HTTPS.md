# Переезд на домен + HTTPS

Зачем: HTTP на голый IP читается любым Wi-Fi по дороге (локации водителей),
а App Review заворачивает `NSAllowsArbitraryLoads`. Подпись OTA (Ed25519)
уже защищает базу камер даже на HTTP, но трафик локаций закрывает только TLS.

## Шаги (на VPS, после покупки домена)

1. A-запись домена → 45.130.148.94; подождать резолва (`dig +short домен`).
2. В `nginx-radarmap.conf` вписать `server_name домен;` и применить конфиг:
   `nginx -t && systemctl reload nginx`.
3. Выпустить сертификат (не трогает чужие проекты на VPS):
   ```
   apt install -y certbot python3-certbot-nginx
   certbot --nginx -d домен --redirect
   ```
   Автопродление certbot ставит сам (systemd timer).
4. Сказать Клоду домен — в приложении меняется одна строка
   (`AppConfig.syncBaseURL`) и удаляется `NSAllowsArbitraryLoads` из Info.plist;
   опционально добавляется пиннинг ключа сертификата.

## Что уже защищено без HTTPS

- OTA-база камер: Ed25519-подпись, `fail closed` (RemoteSyncService).
- API: суточные капы per-device (api.py) + per-IP rate-limit (nginx).
- Приватность: device-UUID ротируется раз в 30 дней.
