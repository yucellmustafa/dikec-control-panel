#!/system/bin/sh
# www/auth.inc — token-auth helpers for api.cgi
# Source this file; it expects DCP_DATA to be set by the caller.
# Exports: auth_check_token  (exits 0 after writing 403 JSON on failure)
#          _auth_deny        (internal; write 403 and exit)

# Emit a 403 JSON response and exit.
# Called before any body is written; Status: header triggers busybox httpd
# to set the HTTP response code correctly.
_auth_deny() {
    printf 'Status: 403 Forbidden\r\nContent-Type: application/json\r\n\r\n'
    printf '{"ok":false,"error":"unauthorized"}\n'
    exit 0
}

# auth_check_token SUPPLIED_TOKEN
#   Compare SUPPLIED_TOKEN against the stored panel_token.
#   Security properties:
#     - Empty stored token → always deny  (unconfigured panel)
#     - Empty supplied token → always deny (missing ?token=)
#     - Length checked before content (constant-time-ish; avoids prefix match)
#     - Token is NEVER logged
auth_check_token() {
    local _supplied="$1"
    local _stored

    _stored=$(cat "$DCP_DATA/conf/panel_token" 2>/dev/null | tr -d '\r\n' || printf '')

    # Must have a stored token
    [ -n "$_stored" ] || _auth_deny

    # Must have a supplied token
    [ -n "$_supplied" ] || _auth_deny

    # Length must match (prevents empty-stored-token bypass and prefix attacks)
    [ ${#_supplied} -eq ${#_stored} ] || _auth_deny

    # Value must match
    [ "$_supplied" = "$_stored" ] || _auth_deny
}
