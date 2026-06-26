# Changelog

## v0.1.0 — İlk sürüm
İlk public sürüm. ZTE F50 için xray tabanlı VPN + web panel + Telegram bot + SMS merkezi, hepsi tek ortak backend (`lib/action.sh`).

- **Xray VPN:** vmess/vless/trojan + abonelik import; tun0/tproxy; profil hız testi → en hızlıya geç; allowInsecure→cert-pin (xray 26.3.27); tun0 route için kalıcı bekçi (netd flush'a karşı).
- **Web panel:** profesyonel + mobil uyumlu; kullanıcı/şifre login (ilk girişte zorunlu sıfırlama); ADB'den şifre yönetimi; localhost/LAN.
- **Telegram bot:** 80+ komut + VPN/Xray/adblock/SMS kontrolü; 12 dil.
- **SMS merkezi:** oku/gönder/sil + SMS ile uzaktan komut (gizli kod + whitelist + rate-limit).
- **Adblock:** dnsmasq sinkhole (AdGuard Home yerine).
- **Per-client bypass · Entegrasyon yönetimi** (Tailscale/SSH/Tor başlat-durdur).
- **Self-update** (latest.txt + SHA256).
