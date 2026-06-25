# Dikec Control Panel — Tasarım Dokümanı (Spec)

**Tarih:** 2026-06-26
**Modül id:** `dikec-control-panel`
**Hedef cihaz:** ZTE F50 / MU300 — Android 13, arm64-v8a, Magisk, Toybox userspace, ~1.4 GB RAM
**Tip:** Tek Magisk modülü (mega-modül) — mevcut `statusbot`'u içine alır ve emekliye ayırır.

---

## 1. Amaç

ZTE F50 4G router için, **xray binary'leri ile doğrudan çalışan** (APK/V2rayTun VPN'i bırakarak), **web paneli + Telegram botu + SMS merkezi**ni tek tutarlı backend üzerinde birleştiren kapsamlı bir kontrol paneli. `git@github.com:dikeckaan/zte-g5-cpe-xray.git` (OpenWrt/ZTE G5 CPE) panelinin F50'ye uyarlanabilir TÜM özellikleri + mevcut `statusbot`'un tüm özelliklerini taşır.

### Kullanıcı kararları (onaylı)
1. **Bot mimarisi:** Tek mega-modül — statusbot içeri alınır, eski statusbot modülü emekliye ayrılır.
2. **Xray yönlendirme:** İki mod, panelden seçilir — `tun0` (varsayılan, vpn-gateway uyumlu) + `tproxy` (opsiyonel, performans).
3. **Panel erişimi:** Varsayılan `127.0.0.1`; panelden "LAN'a aç" anahtarı (basic-auth zorunlu).
4. **SMS:** Tam SMS merkezi (gelen kutusu/gönder/sil) + SMS-ile-uzaktan-komut (whitelist+secret+rate-limit).

### Kritik kısıt: KAYNAK
Cihaz çok dar (boşta ~40 MB RAM, zram swap ile ayakta, 8 çekirdek sürekli yüklü). **Panel cihazı boğmamalı.** Bkz. §7 Kaynak Disiplini.

---

## 2. Mimari — Tek kaynak (`lib/action.sh` dispatcher)

Bot ve web panelinin aynı backend'i paylaşması, **tüm cihaz mantığını `lib/core/*.sh` içinde tek kaynak** yapıp ikisinin de tek bir `lib/action.sh <verb> [json] → JSON` dispatcher'ı üzerinden çağırmasıyla garanti edilir. Hiçbir mantık iki yerde tekrarlanmaz; yeni özellik = yeni verb, anında hem bot hem panelde görünür.

```
        Telegram ──► bot/bot.sh ─┐                 ┌─ www/api.cgi ◄── Web (busybox httpd)
                                 ├──► lib/action.sh ◄──┤
        SMS-cmd ──► sms_cmd.sh ──┘   (verb → JSON)     └─ (CLI: action.sh çağrılabilir)
                                          │
   lib/core/{env,at,sms,sms_cmd,system,xray,routing,profiles,modules,integrations,notify}.sh
                                          │
        sendat (AT) · content query · iptables/ip · xray · hev-socks5-tunnel · curl/jq
```

**Sözleşme:** `action.sh` her zaman tek satır JSON döndürür (`{"ok":true,...}` / `{"ok":false,"err":"..."}`). Bot bunu Telegram metnine biçimler; CGI doğrudan HTTP gövdesi olarak verir. JSON üretimi `jq -n` ile (bin-utils jq).

---

## 3. Dizin yapısı

```
magisk-modules/dikec-control-panel/
├── module.prop              id=dikec-control-panel  name="Dikec Control Panel"  author=dikeckaan
├── customize.sh             bin-utils dep kontrolü; statusbot config göçü; statusbot'u disable; set_perm
├── service.sh               boot supervisor → {httpd, bot}; (xray yalnızca enabled ise)
├── uninstall.sh             temizlik; statusbot geri-yükleme seçeneği
├── update.json              versionCode/zipUrl/sha256 (ekosistemle aynı)
├── META-INF/com/google/android/{update-binary,updater-script}
├── lib/
│   ├── action.sh            DISPATCHER — bot + CGI tek giriş noktası
│   └── core/
│       ├── env.sh           yollar, bin keşfi, bin-utils common.sh source, CA bundle
│       ├── at.sh            sendat sarmalayıcıları (sinyal, cellinfo, imei, band, cfun, raw AT)
│       ├── sms.sh           oku (content query) / sil (content delete) / gönder (AT+CMGS)
│       ├── sms_cmd.sh       SMS uzaktan-komut motoru (whitelist+secret+allow-list+rate-limit)
│       ├── system.sh        mem/cpu/temp/uptime/loadavg/throughput/clients/ip  (+15s cold cache)
│       ├── xray.sh          start/stop/restart/status/log; config doğrulama (xray -test)
│       ├── profiles.sh      import (vmess/vless/trojan + subscription) / list / switch / probe / delete
│       ├── routing.sh       route_mode tun0|tproxy; vpn-gateway seam; per-client bypass (iptables)
│       ├── modules.sh       diğer magisk modüllerini kur/güncelle (katalog) [statusbot'tan]
│       ├── integrations.sh  adguardhome/tor/tailscale/ssh/traffic-stats passthrough [statusbot'tan]
│       └── notify.sh        Telegram + SMS bildirim yardımcıları
├── bot/
│   ├── bot.sh               statusbot refactor: ince TG frontend, lib/core + action.sh kullanır
│   └── lang/<code>.sh       12 dil i18n (taşınır)
├── www/
│   ├── index.html           "Dikec Control Panel" SPA kabuğu
│   ├── app.js · app.css     vanilla JS/CSS (framework yok)
│   ├── api.cgi              bash CGI → lib/action.sh
│   ├── httpd.conf           busybox httpd yapılandırması
│   └── auth.inc             token / basic-auth
├── xray/
│   ├── config.tpl.json      base şablon (socks-in + dokodemo-in + outbound iskeleti)
│   └── assets/{geoip.dat,geosite.dat}
├── system/bin/
│   ├── xray                 arm64 statik
│   └── hev-socks5-tunnel    tun2socks (tun0 modu için)
└── docs/specs/...           bu doküman + plan
```

**Runtime veri kökü:** `/data/dikec/`
```
/data/dikec/
├── token  chat_id  lang            (statusbot'tan göç)
├── xray/{config.json, profiles/config-*.json, active}
├── conf/{route_mode, lan_expose, panel_token, sms-control.conf, cell-watch.conf, schedules.txt, ...}
├── sms/                            (state: işlenmiş SMS ts, forward durumu)
└── logs/{panel.log, bot.log, xray.log, service.log}
```

---

## 4. Bileşenler

### 4.1 Xray motoru (binary ile, APK değil)
- **Binary'ler:** `xray` (arm64 statik) + `hev-socks5-tunnel` (tun2socks). xray'in native TUN inbound'u olmadığı için tun0 modunda tun2socks şart.
- **Supervisor:** `service.sh` yalnızca `enabled` durumda xray + (tun0 modunda) hev-socks5-tunnel başlatır; bin-utils `supervisor_loop` ile çökme-yeniden başlatma. Devre dışıyken hiç process yok (RAM tasarrufu).
- **Config:** `xray/config.tpl.json` → `/data/dikec/xray/config.json`. Yerel `socks` inbound `127.0.0.1:10808` (tun0 modu) + `dokodemo-door` inbound (tproxy modu). `xray -test` ile doğrulama.
- **Go CA:** `SSL_CERT_FILE` = bin-utils cacert.pem (geo güncelleme / abonelik fetch için).

### 4.2 Yönlendirme — iki mod (`lib/core/routing.sh`)
`/data/dikec/conf/route_mode` ∈ {`tun0`, `tproxy`}. Panelden ve bottan (`/xray route ...`) değişir; iki mod birbirini dışlar.

- **tun0 (varsayılan, vpn-gateway uyumlu):** xray socks `127.0.0.1:10808` → hev-socks5-tunnel `tun0`'ı kurar → **vpn-gateway'in mevcut kuralları** (RFC1918 → tun0) trafiği taşır. vpn-gateway'e dokunulmaz. Mod aktifken vpn-gateway kurulu değilse panel uyarır.
- **tproxy (opsiyonel):** xray dokodemo-door + kendi iptables TPROXY/mangle zinciri (zte `tproxy.sh`'ından port). vpn-gateway bypass edilir.
- **Per-client bypass:** `bypass.list` + iptables `RETURN` kuralları (zte mantığı, her iki modda). Panelde cihaz başına anahtar.

### 4.3 SMS merkezi (`lib/core/sms.sh`, `sms_cmd.sh`)
- **Okuma:** `content query content://sms/inbox --projection _id:address:body:date:read` (sms-cmd modülündeki kanıtlanmış yöntem). Panelde konuşma görünümü, okundu işaretleme.
- **Silme:** `content delete content://sms/inbox --where "_id=<id>"`.
- **Gönderme:** `AT+CMGS="<no>"` (sendat) — UTF-8↔UCS-2 BE hex dönüşümü.
- **Uzaktan komut (sms_cmd.sh):** zte `sms-control` portu. Format `<SECRET> <komut> [arg]`. Komutlar: `durum`, `vpn ac|kapat|yeniden|<profil>`, `vpn import <link>`, `ip`, `reboot`, `wifi on|off`, `locate`, `panic`. Auth: telefon whitelist + paylaşılan secret + izinli-komut listesi + rate-limit. **sms-cmd modülü konvansiyonlarıyla uyumlu** (çakışmayı önlemek için: sms-cmd kuruluysa panel onun config'ini yönetir; değilse kendi motorunu kullanır). Gelen komut Telegram'a forward edilir.
- **Yoklama:** Ayrı cron YOK — bot long-poll döngüsündeki `poll_sms_*` fonksiyonuna katlanır (statusbot'ta zaten var).

### 4.4 Cellular (`lib/core/at.sh`) — F50'de gerçek AT avantajı
zte paneli AT'yi ubus'tan emüle ediyordu; F50'de `sendat` ile **gerçek AT** var (statusbot kanıtlı). Bu yüzden zte'de "modem-specific/NO" olan birçok şey F50'de çalışır:
- Sinyal: `AT+CSQ`, `AT+CESQ` (RSSI/RSRP/RSRQ/SNR)
- Cellinfo: `AT+COPS?`, `AT+CGSN` (IMEI), `AT+CCID`/`AT+CIMI` (ICCID/IMSI), `AT+CNUM`
- Cell radar / komşu hücre: `AT+CCED` (cell-tools modülü mantığı) + geolocation (Google/BeaconDB — statusbot'ta var)
- Airplane: `AT+CFUN`
- Ham AT çalıştırıcı (panel + bot `/at`)
- **Band lock:** yalnızca AT destekliyorsa best-effort, **deneysel** işaretli (zte'nin band-optimizer binary'si TAŞINMAZ).

### 4.5 Web panel (`www/`)
- **Sunucu:** busybox httpd + bash CGI (`api.cgi`). Kalıcı backend process yok; CGI istek başına kısa ömürlü.
- **Erişim:** varsayılan `127.0.0.1` (sürtünmesiz token). Panelde **"LAN'a aç"** anahtarı → httpd `0.0.0.0`/br0'a yeniden bağlanır + **basic-auth zorunlu**. Durum `/data/dikec/conf/lan_expose`.
- **Sayfalar:** Dashboard (durum/sinyal/CPU/RAM/temp + log) · Xray (profiller/import/abonelik/route mode/probe/aç-kapa/config editör) · SMS (gelen kutusu/gönder/uzaktan-komut config) · Cellular (sinyal/cellinfo/cell radar/AT) · Clients (bypass) · Integrations (AdGuard/Tor/Tailscale/SSH) · System (update/reboot/password/web shell/backup/schedule).
- **Frontend:** vanilla, framework yok; sekme gizliyken polling durur; konfigüre edilebilir aralık.

### 4.6 Telegram bot (`bot/bot.sh`)
- statusbot'un ~80 komutu refactor edilip korunur (artık `lib/core` + `action.sh` üzerinden). Yeni: `/xray`, `/import`, gelişmiş SMS verb'leri.
- Tek token/chat_id `/data/dikec`'ten (statusbot'tan göç). Long-poll + `poll_*` (heartbeat, schedules, sms-forward, tasks) — **tek bash döngüsü**, ekstra process yok.

### 4.7 Entegrasyonlar (mevcut modüller — yeniden yazılmaz, yüzeylenir)
- **DNS/Adblock:** zte'nin dnsmasq-adblock'u TAŞINMAZ; bunun yerine mevcut **adguardhome** modülü panel/bottan yönetilir (start/stop/log/query).
- **Tailscale** (tailscale-control), **Tor** (tor-relay), **SSH** (dropbear-ssh), **traffic-stats**, **clients**, **module install/update** — statusbot'taki entegrasyonlar `integrations.sh`'a taşınır.

### 4.8 Self-update & watchdog
- **Update:** zte-update portu — `latest.txt` kontrol + SHA256 + zip + reinstall. Bottan/panelden onaylı.
- **Watchdog/service-guard:** Ayrı cron/daemon YOK; servis-sağlık kontrolü `service.sh` supervisor döngüsüne + bot `poll_*`'a katlanır.

---

## 5. Taşınan özellik kapsamı (zte paneli → F50)

**DAHİL (Tier 1 + F50'ye uyan Tier 2):**
Xray core (start/stop/restart/switch), profiller (list/switch/save/edit/delete), **vmess/vless/trojan import + abonelik URL import** (xray-import portu, multi-profil), probe/latency + "en hızlıya geç", per-client bypass, backup/restore, config editör, route-mode toggle (F50'ye özgü ekleme), throughput/monitor, status tiles (15s cache), **SMS merkezi + SMS uzaktan-komut**, cellular (sinyal/cellinfo/cell-radar/geolocation/AT/airplane via sendat), Tailscale, SSH, AdGuard (adblock yerine), Tor, update (self-update), reboot/password/web-shell/file/backup, scheduling (bot poll döngüsü — cron yok), QR, Telegram bildirim.

**STUB/DENEYSEL:** band lock (yalnızca AT, deneysel), HTTPS panel (opsiyonel 2. xray — sonraya), Tailscale-egress-via-VPN (2. xray — sonraya).

**HARİÇ (taşınmaz, donanım/modem'e özgü):** band-optimizer binary, APN set, network-mode (4G/5G NSA/SA) set, NFC WiFi paylaşımı, modem-ttl binary, ZTE USB modları, carrier-aggregation readout, dnsmasq-adblock (adguardhome ile ikame).

---

## 6. Diğer modüllerle uyumluluk

- **bin-utils:** sert bağımlılık (customize.sh kontrolü, adguardhome deseni). bash/busybox/curl/jq/sendat/wget + `lib/common.sh` (log_line/log_rotate/find_ca_bundle/wait_for_iface/supervisor_loop) kullanılır.
- **vpn-gateway:** tun0 modunda dokunulmadan kullanılır; xray tun0'ı sağlar, vpn-gateway LAN→tun0 yönlendirir.
- **sms-cmd:** çakışma yok; kuruluysa config'i yönetilir, değilse kendi motoru.
- **statusbot:** içeri alınır + emekliye ayrılır (customize.sh: config göçü + `statusbot/disable`). uninstall.sh geri-yükleme seçeneği sunar.
- **Paketleme:** GitHub Actions ile module.prop değişiminde versiyonlu zip + update.json (ekosistemle aynı). Yerel kurulum zip'i de üretilir.

---

## 7. Kaynak disiplini (RAM/CPU — cihazı boğmama)

Cihaz boşta ~40 MB RAM. Tasarım ilkeleri:
1. **Yeni kalıcı daemon YOK.** Çalışan process'ler: busybox httpd (~1-2 MB), bot (tek bash döngüsü — statusbot'u **değiştirir**, net sıfır), xray+tun2socks (**yalnızca VPN açıkken**).
2. **Tüm periyodik iş tek bot döngüsüne katlanır** (watchdog, schedules, sms-poll, cell-watch, heartbeat) — cron/ekstra process yok.
3. **CGI istek-ömürlü** kısa bash; kalıcı panel backend yok.
4. **Cold cache (15s TTL)** — CPU/RAM/temp/sinyal tekrar okunmaz; AT çağrıları minimumda.
5. **Log rotasyonu** bin-utils `log_rotate` (512 KB cap).
6. **xray config yalın** (gereksiz sniffing/route kuralı yok); APK-VPN'e (V2rayTun) göre net RAM kazancı (LMK kill'leri azalır).
7. **Frontend** framework'süz; sekme gizliyken polling durur; ayarlanabilir aralık; httpd varsayılan localhost.
8. **Speedtest gibi ağır işler opsiyonel/manuel**; varsayılan latency probe (1-2 sn).

**Hedef ek bellek bütçesi:** xray kapalıyken < ~8 MB (httpd + bot, statusbot'un yerini aldığı için pratikte ~0 net); xray açıkken ~20-30 MB (ama V2rayTun APK'sından daha az).

---

## 8. Kurulum / kaldırma / temizlik

- **customize.sh:** bin-utils kontrolü → statusbot config göçü (`/data/statusbot/*` → `/data/dikec/*`) → statusbot disable → binary izinleri (set_perm xray, hev-socks5-tunnel, *.sh, *.cgi).
- **Bozuk dcp-engine kaldırma:** Cihazdan `dcp-engine` modülü kaldırılır; yerel eski `~/f50-remote-adb/dikec-control-panel` (top-level) dizini ve `dcp-engine-v0.1.0-f50.zip` temizlenir (yeni modül `magisk-modules/dikec-control-panel`'de).
- **uninstall.sh:** `/data/dikec` temizliği; statusbot'u tekrar enable etme seçeneği.

---

## 9. Test / doğrulama stratejisi

- **Birim:** her `lib/core/*.sh` fonksiyonu cihazda `action.sh <verb>` ile doğrulanır (JSON çıktı kontrolü).
- **Entegrasyon:** xray tun0 modu → vpn-gateway ile gerçek trafik (curl through, IP değişimi); tproxy modu ayrı.
- **SMS:** gerçek gelen kutusu okuma + test SMS gönder + uzaktan-komut (whitelist/secret/rate-limit).
- **Panel:** localhost'tan tüm sayfalar; LAN-aç anahtarı + basic-auth.
- **Bot:** kritik komutlar + yeni xray/SMS verb'leri; panel ile aynı sonucu verdiği doğrulanır (ortak action.sh).
- **Kaynak:** xray kapalı/açık RSS ölçümü; free RAM regresyonu kontrolü.
- **Smoke:** her aşamada cihaza kurulum + reboot + servis ayağa kalkıyor mu.

---

## 10. Aşamalı uygulama (özet — detay plan ayrı)

1. **İskele:** modül yapısı, module.prop, customize/service/uninstall, bin-utils entegrasyonu, /data/dikec, statusbot göçü.
2. **lib/core + action.sh:** env, at, system, sms, xray, profiles, routing (dispatcher sözleşmesi).
3. **Xray motoru:** binary'ler, config şablonu, tun0+tproxy yönlendirme, vpn-gateway seam, import (vmess/vless/trojan + abonelik).
4. **Bot refactor:** statusbot'u lib/core üzerine taşı, yeni xray/SMS verb'leri, emeklilik göçü.
5. **Web panel:** httpd, api.cgi, SPA sayfaları, auth, LAN-aç.
6. **SMS merkezi + uzaktan-komut + entegrasyonlar + self-update.**
7. **Kaynak sıkılaştırma + paketleme (zip/update.json/CI) + dcp-engine temizliği + cihaz uçtan uca test.**
```
