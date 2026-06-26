#!/system/bin/sh
# Dikec Control Panel kurulum betiği.

# --- bin-utils sert bağımlılığı (adguardhome deseni) ---
if [ ! -r /data/adb/modules/bin-utils/lib/common.sh ] \
   && [ ! -r /data/adb/modules_update/bin-utils/lib/common.sh ]; then
    ui_print " "
    ui_print "  ❌ bin-utils v1.3.0+ gerekli (lib/common.sh sağlar)."
    ui_print "     Önce kur:  /install_module bin-utils"
    abort "  Eksik bağımlılık: bin-utils"
fi

DATA=/data/dikec
mkdir -p "$DATA"/xray/profiles "$DATA"/conf "$DATA"/sms "$DATA"/logs "$DATA"/adblock

# --- statusbot config göçü (varsa, üzerine yazma) ---
SB=/data/statusbot
if [ -d "$SB" ]; then
    ui_print "  → statusbot ayarları taşınıyor (/data/dikec)"
    for f in token chat_id lang quiet_hours.conf heartbeat.conf schedules.txt zte_password geo_api_key; do
        [ -f "$SB/$f" ] && [ ! -f "$DATA/$f" ] && cp -a "$SB/$f" "$DATA/$f"
    done
fi

# --- statusbot'u emekliye ayır (çakışan bot çalışmasın) ---
if [ -d /data/adb/modules/statusbot ]; then
    ui_print "  → statusbot devre dışı bırakılıyor (bu modül onu kapsar)"
    touch /data/adb/modules/statusbot/disable
fi

# --- AdGuard Home'u kaldır (panel-native adblock devralır) ---
if [ -d /data/adb/modules/adguardhome ]; then
    ui_print "  → AdGuard Home devre dışı bırakılıyor (hafif dnsmasq adblock kullanılacak)"
    touch /data/adb/modules/adguardhome/disable
    touch /data/adb/modules/adguardhome/remove
fi

# --- panel token (yoksa üret) ---
[ -f "$DATA/conf/panel_token" ] || tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 32 > "$DATA/conf/panel_token"
[ -s "$DATA/conf/route_mode" ] || echo tun0 > "$DATA/conf/route_mode"
[ -s "$DATA/conf/lan_expose" ] || echo 0 > "$DATA/conf/lan_expose"

# --- izinler ---
set_perm_recursive "$MODPATH" 0 0 0755 0644
for x in xray hev-socks5-tunnel; do
    [ -f "$MODPATH/system/bin/$x" ] && set_perm "$MODPATH/system/bin/$x" 0 0 0755
done
find "$MODPATH/lib" "$MODPATH/bot" "$MODPATH/www" -name '*.sh' -o -name '*.cgi' 2>/dev/null | while read -r f; do
    set_perm "$f" 0 0 0755
done

ui_print " "
ui_print "  ✅ Dikec Control Panel kuruldu. Reboot sonrası:"
ui_print "     • Bot token/chat_id: /data/dikec/{token,chat_id}"
ui_print "     • Panel: http://127.0.0.1:8088 (adb forward / tünel)"
