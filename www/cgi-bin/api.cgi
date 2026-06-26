#!/system/bin/sh
# www/api.cgi — HTTP → lib/action.sh bridge
#
# Invoked by busybox httpd as CGI for any /api.cgi request.
#
# Supported call forms:
#   GET  /api.cgi?verb=<v>&arg=<a>&token=<t>
#   POST /api.cgi  body=application/json  {"verb":"...","arg":"...","token":"..."}
#   POST /api.cgi  body=application/x-www-form-urlencoded  verb=...&arg=...&token=...
#
# SECURITY:
#   1. verb and arg are ALWAYS passed as separate argv elements to action.sh.
#      They are NEVER eval'd, interpolated into a command string, or passed
#      through sh -c.  A verb of "status;reboot" or "$(cmd)" executes nothing.
#   2. URL-decoding is done by busybox httpd -d (a C binary call), not eval.
#   3. verb is validated to [a-zA-Z0-9_] only; anything else → 400.
#   4. The token is compared in auth.inc; never logged.
#   5. arg is passed through to action.sh; action.sh is responsible for
#      validating its own arguments.

DCP=/data/adb/modules/dikec-control-panel
DCP_DATA=/data/dikec
BB=/data/adb/modules/bin-utils/system/bin/busybox
JQ=/data/adb/modules/bin-utils/system/bin/jq

. "$DCP/www/auth.inc"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Emit an error JSON response with the given HTTP status and exit.
http_error() {
    # $1 = "NNN Reason"  $2 = JSON body string
    printf 'Status: %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2"
    exit 0
}

# URL-decode a string: convert + to space, then decode %XX with busybox.
# The decoded result is returned on stdout; it is NEVER eval'd.
url_decode() {
    local _enc
    # Form-encoded: replace + with space first
    _enc=$(printf '%s' "$1" | sed 's/+/ /g')
    # Percent-decode via busybox httpd -d (safe: passes as a single quoted arg)
    "$BB" httpd -d "$_enc" 2>/dev/null || printf '%s' "$_enc"
}

# Extract the URL-decoded value of a named parameter from a query string.
# $1 = param name (hardcoded in caller — not user-controlled)
# $2 = query string
qs_param() {
    local _name="$1" _qs="$2" _raw
    # Split on & and grep for the named key; cut everything after first '='
    _raw=$(printf '%s' "$_qs" \
           | tr '&' '\n' \
           | grep "^${_name}=" \
           | head -1 \
           | cut -d= -f2-)
    url_decode "$_raw"
}

# ---------------------------------------------------------------------------
# Parse request
# ---------------------------------------------------------------------------

VERB_RAW=""
ARG_RAW=""
ARG2_RAW=""
TOKEN_RAW=""

if [ "$REQUEST_METHOD" = "POST" ] \
   && [ -n "$CONTENT_LENGTH" ] \
   && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then

    # Read at most 65536 bytes to prevent DoS
    _MAX=65536
    [ "$CONTENT_LENGTH" -gt "$_MAX" ] && CONTENT_LENGTH=$_MAX

    BODY=$("$BB" dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)

    case "$CONTENT_TYPE" in
        application/json*)
            # Use jq to parse; no shell injection possible
            TOKEN_RAW=$(printf '%s' "$BODY" | "$JQ" -r '.token  // empty' 2>/dev/null)
            VERB_RAW=$( printf '%s' "$BODY" | "$JQ" -r '.verb   // empty' 2>/dev/null)
            ARG_RAW=$(  printf '%s' "$BODY" | "$JQ" -r '.arg    // empty' 2>/dev/null)
            ARG2_RAW=$( printf '%s' "$BODY" | "$JQ" -r '.arg2   // empty' 2>/dev/null)
            ;;
        *)
            # Form-encoded POST body; treat like QUERY_STRING
            TOKEN_RAW=$(qs_param token "$BODY")
            VERB_RAW=$(qs_param  verb  "$BODY")
            ARG_RAW=$(qs_param   arg   "$BODY")
            ARG2_RAW=$(qs_param  arg2  "$BODY")
            ;;
    esac
else
    # GET (or POST with empty body): use QUERY_STRING
    TOKEN_RAW=$(qs_param token "$QUERY_STRING")
    VERB_RAW=$(qs_param  verb  "$QUERY_STRING")
    ARG_RAW=$(qs_param   arg   "$QUERY_STRING")
    ARG2_RAW=$(qs_param  arg2  "$QUERY_STRING")
fi

# ---------------------------------------------------------------------------
# Authentication — a valid SESSION COOKIE (human login) OR the panel token
# (automation / localhost) is accepted. Two special verbs are handled here:
#   session — auth probe; returns {authed,user,must_change} WITHOUT requiring auth
#   logout  — destroys the current session cookie
# Everything else requires a valid session or token, else 403.
# ---------------------------------------------------------------------------

. "$DCP/lib/core/panelauth.sh"

# Extract the dcp_sess cookie (if any) from the request.
COOKIE_TOK=$(printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' \
    | sed -n 's/^[[:space:]]*dcp_sess=//p' | head -1 | tr -d '[:space:]')

_AUTHED=0
if pa_session_valid "$COOKIE_TOK"; then
    _AUTHED=1
elif [ -n "$TOKEN_RAW" ]; then
    _STORED=$(cat "$DCP_DATA/conf/panel_token" 2>/dev/null | tr -d '\r\n')
    if [ -n "$_STORED" ] && [ "$TOKEN_RAW" = "$_STORED" ]; then _AUTHED=1; fi
fi

# session — auth-state probe (no auth required; the SPA calls this on load)
if [ "$VERB_RAW" = "session" ]; then
    printf 'Content-Type: application/json\r\n\r\n'
    "$JQ" -nc --argjson a "$_AUTHED" --arg u "$(pa_user)" \
        --argjson mc "$(pa_must_change)" \
        '{ok:true, authed:($a==1), user:$u, must_change:($mc==1)}'
    exit 0
fi

# logout — clear the session
if [ "$VERB_RAW" = "logout" ]; then
    pa_session_destroy "$COOKIE_TOK"
    printf 'Status: 200 OK\r\nContent-Type: application/json\r\n'
    printf 'Set-Cookie: dcp_sess=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict\r\n\r\n'
    printf '{"ok":true}\n'
    exit 0
fi

if [ "$_AUTHED" != "1" ]; then
    http_error "401 Unauthorized" '{"ok":false,"error":"unauthorized"}'
fi

# ---------------------------------------------------------------------------
# Validate verb — must be [a-zA-Z0-9_] only; no semicolons, $, spaces, etc.
# This ensures action.sh receives a clean verb and cannot be tricked by
# shell metacharacters even if exec'ed safely.
# ---------------------------------------------------------------------------

case "$VERB_RAW" in
    ''|*[!a-zA-Z0-9_]*)
        http_error "400 Bad Request" '{"ok":false,"error":"invalid verb"}'
        ;;
esac

# ---------------------------------------------------------------------------
# Dispatch — emit CGI header, then exec action.sh with separate argv elements.
# NEVER: eval, sh -c "action.sh $verb $arg", or any string interpolation.
# ---------------------------------------------------------------------------

if [ ! -x "$DCP/lib/action.sh" ]; then
    http_error "500 Internal Server Error" '{"ok":false,"error":"action.sh not available"}'
fi

printf 'Content-Type: application/json\r\n\r\n'

# exec replaces this shell with action.sh; its JSON output goes directly to
# the HTTP response body.  verb and arg are separate argv — injection-safe.
exec "$DCP/lib/action.sh" "$VERB_RAW" "$ARG_RAW" "$ARG2_RAW"
