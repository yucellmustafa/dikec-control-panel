#!/system/bin/sh
# www/cgi-bin/passwd.cgi — change the panel password. Requires a valid session.
# Body (form-encoded or JSON): new  (and  old  when MUST_CHANGE is not set).
# On success: password updated, MUST_CHANGE cleared, ALL sessions invalidated
# (the client must log in again with the new password).

DCP=/data/adb/modules/dikec-control-panel
DCP_DATA=/data/dikec
BB=/data/adb/modules/bin-utils/system/bin/busybox
JQ=/data/adb/modules/bin-utils/system/bin/jq
. "$DCP/lib/core/panelauth.sh"

_reply() { printf 'Status: %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2"; exit 0; }
url_decode() { local e; e=$(printf '%s' "$1" | sed 's/+/ /g'); "$BB" httpd -d "$e" 2>/dev/null || printf '%s' "$e"; }
qs_param() { local raw; raw=$(printf '%s' "$2" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2-); url_decode "$raw"; }

# ── require a valid session ───────────────────────────────────────────────────
COOKIE_TOK=$(printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' \
    | sed -n 's/^[[:space:]]*dcp_sess=//p' | head -1 | tr -d '[:space:]')
pa_session_valid "$COOKIE_TOK" || _reply "401 Unauthorized" '{"ok":false,"error":"unauthorized"}'

[ "$REQUEST_METHOD" = "POST" ] && [ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null \
    || _reply "405 Method Not Allowed" '{"ok":false,"error":"POST required"}'

_MAX=8192; [ "$CONTENT_LENGTH" -gt "$_MAX" ] && CONTENT_LENGTH=$_MAX
BODY=$("$BB" dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
case "$CONTENT_TYPE" in
    application/json*)
        NEW=$(printf '%s' "$BODY" | "$JQ" -r '.new // empty' 2>/dev/null)
        OLD=$(printf '%s' "$BODY" | "$JQ" -r '.old // empty' 2>/dev/null)
        ;;
    *)
        NEW=$(qs_param new "$BODY"); OLD=$(qs_param old "$BODY")
        ;;
esac

# ── validation ────────────────────────────────────────────────────────────────
case "$NEW" in
    '') _reply "400 Bad Request" '{"ok":false,"error":"new password required"}' ;;
esac
# minimum length 6
if [ "${#NEW}" -lt 6 ]; then
    _reply "400 Bad Request" '{"ok":false,"error":"password too short (min 6)"}'
fi

# When not a forced first-login change, require the current password.
if [ "$(pa_must_change)" != "1" ]; then
    if ! pa_verify "$(pa_user)" "$OLD"; then
        sleep 1
        _reply "403 Forbidden" '{"ok":false,"error":"current password incorrect"}'
    fi
fi

pa_set_password "$NEW"
# pa_set_password invalidated all sessions — clear the cookie too.
printf 'Status: 200 OK\r\nContent-Type: application/json\r\n'
printf 'Set-Cookie: dcp_sess=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict\r\n\r\n'
printf '{"ok":true,"relogin":true}\n'
