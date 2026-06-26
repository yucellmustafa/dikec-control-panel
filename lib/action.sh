#!/system/bin/sh
# lib/action.sh — merkezi dispatcher: action.sh <verb> [arg] → tek satır JSON
# Tüketir: lib/core/{env,system,at,sms,profiles,routing,xray}.sh
# Kullanım: action.sh status | signal | cellinfo | sms_list [n] | airplane <on|off>
#           action.sh xray_start | xray_stop | xray_status
#           action.sh prof_switch <name> | prof_list | prof_import_link <uri>
#           action.sh bypass_add <ip> | bypass_del <ip>

D="${0%/lib/action.sh}"; [ -d "$D/lib" ] || D=/data/adb/modules/dikec-control-panel
. "$D/lib/core/env.sh"
. "$D/lib/core/system.sh"
. "$D/lib/core/at.sh"
. "$D/lib/core/sms.sh"
. "$D/lib/core/profiles.sh"
. "$D/lib/core/routing.sh"
. "$D/lib/core/xray.sh"

VERB="${1:-}"; ARG="${2:-}"
case "$VERB" in
  # ── cell / modem ──────────────────────────────────────────────────────────
  status)          j_ok "$(sys_status_json)";;
  signal)          j_ok "$(at_signal_json)";;
  cellinfo)        j_ok "$(at_cellinfo_json)";;
  sms_list)        j_ok "$(sms_list_json "${ARG:-20}")";;
  airplane)        at_airplane "$ARG" && j_ok '{}' || j_err "airplane $ARG başarısız";;
  # ── profiles ──────────────────────────────────────────────────────────────
  prof_switch)     j_ok "$(prof_switch "$ARG")";;
  prof_list)       j_ok "$(prof_list_json)";;
  prof_import_link) j_ok "$(prof_import_link "$ARG")";;
  prof_import_sub) j_ok "$(prof_import_sub "$ARG")";;
  # ── xray engine ───────────────────────────────────────────────────────────
  xray_start)      xray_start && j_ok '{}' || j_err "xray_start başarısız";;
  xray_stop)       xray_stop  && j_ok '{}' || j_err "xray_stop başarısız";;
  xray_status)     j_ok "$(xray_status_json)";;
  # ── per-client bypass ─────────────────────────────────────────────────────
  bypass_add)      bypass_add "$ARG" && j_ok "{}" || j_err "bypass_add $ARG başarısız";;
  bypass_del)      bypass_del "$ARG" && j_ok "{}" || j_err "bypass_del $ARG başarısız";;
  # ── tproxy dry-run ────────────────────────────────────────────────────────
  tproxy_dryrun)   DRYRUN=1 route_apply tproxy;;
  *)               j_err "bilinmeyen verb: $VERB";;
esac
