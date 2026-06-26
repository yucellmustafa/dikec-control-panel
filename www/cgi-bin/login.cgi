#!/system/bin/sh
# www/cgi-bin/login.cgi — POST user+pass → verify → issue a session cookie.
# Body (form-encoded or JSON): user, pass.
# Response: {ok:true, must_change:<bool>} + Set-Cookie  OR  401 {ok:false}.

DCP=/data/adb/modules/dikec-control-panel
DCP_DATA=/data/dikec
BB=/data/adb/modules/bin-utils/system/bin/busybox
JQ=/data/adb/modules/bin-utils/system/bin/jq
. "$DCP/lib/core/panelauth.sh"

_reply() { # $1 = "NNN Reason", $2 = extra Set-Cookie line (may be empty), $3 = json
    # CGI requires a BLANK line between headers and body. Emit headers, the
    # optional Set-Cookie, then \r\n\r\n, then the JSON body.
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: application/json\r\n'
    [ -n "$2" ] && printf '%s\r\n' "$2"
    printf '\r\n%s\n' "$3"
    exit 0
}

url_decode() {
    local e; e=$(printf '%s' "$1" | sed 's/+/ /g')
    "$BB" httpd -d "$e" 2>/dev/null || printf '%s' "$e"
}
qs_param() {
    local raw; raw=$(printf '%s' "$2" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2-)
    url_decode "$raw"
}

USER_IN=""; PASS_IN=""
if [ "$REQUEST_METHOD" = "POST" ] && [ "${CONTENT_LENGTH:-0}" -gt 0 ] 2>/dev/null; then
    _MAX=8192; [ "$CONTENT_LENGTH" -gt "$_MAX" ] && CONTENT_LENGTH=$_MAX
    BODY=$("$BB" dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    case "$CONTENT_TYPE" in
        application/json*)
            USER_IN=$(printf '%s' "$BODY" | "$JQ" -r '.user // empty' 2>/dev/null)
            PASS_IN=$(printf '%s' "$BODY" | "$JQ" -r '.pass // empty' 2>/dev/null)
            ;;
        *)
            USER_IN=$(qs_param user "$BODY")
            PASS_IN=$(qs_param pass "$BODY")
            ;;
    esac
else
    _reply "405 Method Not Allowed" "" '{"ok":false,"error":"POST required"}'
fi

if pa_verify "$USER_IN" "$PASS_IN"; then
    TOK=$(pa_session_new)
    MC=$(pa_must_change)
    COOKIE="Set-Cookie: dcp_sess=$TOK; Path=/; Max-Age=$PA_SESS_TTL; HttpOnly; SameSite=Strict"
    _reply "200 OK" "$COOKIE" "$("$JQ" -nc --argjson mc "$MC" '{ok:true, must_change:($mc==1)}')"
else
    # small constant delay to blunt brute force
    sleep 1
    _reply "401 Unauthorized" "" '{"ok":false,"error":"invalid credentials"}'
fi
