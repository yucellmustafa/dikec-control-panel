#!/system/bin/sh
# Ortak ortam — her lib/core/*.sh ve action.sh bunu source eder.
DCP_MOD=/data/adb/modules/dikec-control-panel
DCP_DATA=/data/dikec
BU=/data/adb/modules/bin-utils
export PATH="$BU/system/bin:$PATH"
[ -r "$BU/lib/common.sh" ] && . "$BU/lib/common.sh"

CURL="$BU/system/bin/curl"; JQ="$BU/system/bin/jq"
SENDAT="$BU/system/bin/sendat"; BB="$BU/system/bin/busybox"
CA=$(find_ca_bundle 2>/dev/null); export SSL_CERT_FILE="$CA"
LOG="$DCP_DATA/logs/core.log"

dcp_log(){ LOG="$DCP_DATA/logs/core.log" log_line "$*"; }

# JSON çıktı sözleşmesi — tek satır
# Note: ${1:-{}} causes POSIX shells to emit an extra '}'; use a variable default.
_DCP_EMPTYOBJ='{}'
j_ok(){  "$JQ" -nc --argjson d "${1:-$_DCP_EMPTYOBJ}" '{ok:true} + $d'; }
j_err(){ "$JQ" -nc --arg e "$1" '{ok:false, err:$e}'; }

cfg_get(){ cat "$DCP_DATA/conf/$1" 2>/dev/null || printf '%s' "$2"; }
cfg_set(){ mkdir -p "$DCP_DATA/conf"; printf '%s' "$2" > "$DCP_DATA/conf/$1"; }
