/* Dikec Control Panel — app.js
 * Vanilla SPA; no framework, no CDN.
 * All server-provided strings go through textContent / mkEl — never innerHTML interpolation.
 * Endpoint: /cgi-bin/api.cgi?verb=<v>&arg=<a>&token=<t>
 */
(function () {
  'use strict';

  // ── token ────────────────────────────────────────────────────────────────
  var TOKEN = '';

  function initToken() {
    TOKEN = new URLSearchParams(location.search).get('token') || '';
    if (!TOKEN) {
      document.getElementById('token-overlay').classList.add('show');
    }
  }

  // ── api helpers ──────────────────────────────────────────────────────────
  // GET: all short verbs with simple args
  async function api(verb, arg, arg2) {
    var url = '/cgi-bin/api.cgi?verb=' + encodeURIComponent(verb)
            + '&token=' + encodeURIComponent(TOKEN);
    if (arg != null && arg !== '') url += '&arg=' + encodeURIComponent(arg);
    if (arg2 != null && arg2 !== '') url += '&arg2=' + encodeURIComponent(arg2);
    try {
      var r = await fetch(url);
      var t = await r.text();
      try { return JSON.parse(t); } catch (e) { return { ok: false, err: t }; }
    } catch (e) {
      return { ok: false, err: 'network' };
    }
  }

  // POST JSON: for import verbs where arg can be a long URI or JSON payload
  async function apiPost(verb, arg, arg2) {
    var body = JSON.stringify({
      verb: verb,
      token: TOKEN,
      arg: arg || '',
      arg2: arg2 || ''
    });
    try {
      var r = await fetch('/cgi-bin/api.cgi', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: body
      });
      var t = await r.text();
      try { return JSON.parse(t); } catch (e) { return { ok: false, err: t }; }
    } catch (e) {
      return { ok: false, err: 'network' };
    }
  }

  // ── toast ────────────────────────────────────────────────────────────────
  function toast(msg, kind, ms) {
    var d = document.createElement('div');
    d.className = 'toast' + (kind === 'ok' ? ' ok' : kind === 'err' ? ' err' : '');
    d.textContent = msg;  // XSS-safe
    document.getElementById('toasts').appendChild(d);
    var delay = ms != null ? ms : (kind === 'err' ? 5000 : 3000);
    setTimeout(function () {
      d.style.opacity = '0';
      setTimeout(function () { if (d.parentNode) d.parentNode.removeChild(d); }, 260);
    }, delay);
  }

  // ── DOM helpers ──────────────────────────────────────────────────────────
  // mkEl: creates an element — text is always set via textContent (XSS-safe)
  function mkEl(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;  // XSS-safe
    return e;
  }

  // tx: set textContent — never innerHTML — for server-provided strings
  function tx(id, v) {
    var e = document.getElementById(id);
    if (e) e.textContent = (v == null || v === '') ? '—' : String(v);  // XSS-safe
  }

  function setBar(id, pct) {
    var e = document.getElementById(id);
    if (e) e.style.width = Math.max(0, Math.min(100, Number(pct) || 0)) + '%';
  }

  // kv: creates a key/value row using textContent throughout (XSS-safe)
  function kv(key, val) {
    var row = mkEl('div', 'kv');
    row.appendChild(mkEl('span', 'k', key));
    // val may be null/empty → show —
    row.appendChild(mkEl('span', 'v', (val == null || val === '') ? '—' : String(val)));  // XSS-safe
    return row;
  }

  // ── poll scheduler ────────────────────────────────────────────────────────
  var _pollT = null;

  function sched(fn, ms) {
    clearTimeout(_pollT);
    if (!document.hidden) {
      _pollT = setTimeout(fn, ms || 3000);
    }
  }

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) {
      loadTab(activeTab);
    } else {
      clearTimeout(_pollT);
    }
  });

  // ── tab management ────────────────────────────────────────────────────────
  var TABS = ['dash', 'xray', 'sms', 'cellular', 'clients', 'integrations', 'system'];
  var activeTab = 'dash';

  function switchTab(id) {
    clearTimeout(_pollT);
    TABS.forEach(function (t) {
      document.getElementById('tab-' + t).classList.toggle('active', t === id);
      document.getElementById('view-' + t).classList.toggle('active', t === id);
    });
    activeTab = id;
    loadTab(id);
  }

  function loadTab(id) {
    switch (id) {
      case 'dash':         pollDash();         break;
      case 'xray':         loadXray();         break;
      case 'sms':          loadSms();          break;
      case 'cellular':     loadCellular();     break;
      case 'clients':      loadClients();      break;
      case 'integrations': loadIntegrations(); break;
      case 'system':       loadSystem();       break;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DASHBOARD
  // ─────────────────────────────────────────────────────────────────────────

  function buildDash() {
    // Static HTML scaffold only — no server data interpolated here
    document.getElementById('view-dash').innerHTML = [
      '<div class="grid g2">',
        '<div class="card">',
          '<h3>Device</h3>',
          '<div id="d-device-kvs"></div>',
        '</div>',
        '<div class="card">',
          '<h3>Signal</h3>',
          '<div id="d-signal-kvs"></div>',
        '</div>',
      '</div>',
      '<div class="grid g2">',
        '<div class="card">',
          '<div class="tile">',
            '<div class="k">CPU</div>',
            '<div class="v"><span id="d-cpu">—</span><small>%</small></div>',
            '<div class="bar"><i id="d-cpu-bar" style="background:var(--primary);width:0"></i></div>',
          '</div>',
        '</div>',
        '<div class="card">',
          '<div class="tile">',
            '<div class="k">Memory</div>',
            '<div class="v"><span id="d-mem">—</span><small>%</small></div>',
            '<div class="bar"><i id="d-mem-bar" style="background:var(--ok);width:0"></i></div>',
          '</div>',
        '</div>',
      '</div>'
    ].join('');
  }

  async function pollDash() {
    if (activeTab !== 'dash' || document.hidden) return;

    var results = await Promise.all([api('status'), api('signal')]);
    var st = results[0], sig = results[1];

    var dkvs = document.getElementById('d-device-kvs');
    if (st && st.ok && dkvs) {
      dkvs.textContent = '';
      var up = Number(st.uptime_s) || 0;
      var h = Math.floor(up / 3600), m = Math.floor((up % 3600) / 60);
      // Each value passed via kv() → textContent — XSS-safe
      [
        ['Model',  st.model],
        ['Uptime', h + 'h ' + m + 'm'],
        ['Temp',   st.temp_c != null ? st.temp_c + ' °C' : null],
        ['Load',   st.load1]
      ].forEach(function (p) { dkvs.appendChild(kv(p[0], p[1])); });

      var cpuPct = Number(st.cpu_pct) || 0;
      var memPct = (st.mem_total_mb && st.mem_total_mb > 0)
        ? Math.round(st.mem_used_mb / st.mem_total_mb * 100) : 0;
      tx('d-cpu', cpuPct);
      tx('d-mem', memPct);
      setBar('d-cpu-bar', cpuPct);
      setBar('d-mem-bar', memPct);
    }

    var skvs = document.getElementById('d-signal-kvs');
    if (sig && sig.ok && skvs) {
      skvs.textContent = '';
      [
        ['CSQ',      sig.csq],
        ['RSSI',     sig.rssi_dbm != null ? sig.rssi_dbm + ' dBm' : null],
        ['RSRP idx', sig.rsrp || null],
        ['RSRQ idx', sig.rsrq || null]
      ].forEach(function (p) { skvs.appendChild(kv(p[0], p[1])); });
    }

    sched(pollDash, 3000);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // XRAY
  // ─────────────────────────────────────────────────────────────────────────

  function buildXray() {
    // Static scaffold — no server values interpolated
    document.getElementById('view-xray').innerHTML = [
      '<div class="card">',
        '<h3>Xray Engine <span id="xray-pill" class="pill">—</span></h3>',
        '<div id="xray-stat-kvs"></div>',
        '<div class="row" style="margin-top:12px">',
          '<button class="btn ok sm" id="xray-start">&#9654; Start</button>',
          '<button class="btn danger sm" id="xray-stop">&#9632; Stop</button>',
        '</div>',
      '</div>',
      '<div class="card">',
        '<h3>Route Mode <span id="route-pill" class="pill primary">—</span></h3>',
        '<div class="row">',
          '<button class="btn sm" id="rm-tun0">tun0 (TUN/UDP)</button>',
          '<button class="btn sm" id="rm-tproxy">tproxy (transparent)</button>',
        '</div>',
        '<p class="hint">Switch takes effect immediately if Xray is running.</p>',
      '</div>',
      '<div class="card">',
        '<h3>Profiles <span class="spacer"></span>',
          '<button class="btn ghost sm" id="prof-probe">&#9201; Test speeds</button>',
          '<button class="btn ghost sm" id="prof-refresh">&#8635; Refresh</button>',
        '</h3>',
        '<div id="prof-list"></div>',
        '<div id="probe-results"></div>',
      '</div>',
      '<div class="card">',
        '<h3>Import Link / Subscription</h3>',
        '<div class="field">',
          '<label for="import-input">',
            'vmess:// · vless:// · trojan:// link  — or — https:// subscription URL',
          '</label>',
          '<textarea id="import-input" spellcheck="false"',
            ' placeholder="vmess://...  or  https://sub.example.com/sub"></textarea>',
        '</div>',
        '<div class="row">',
          '<button class="btn primary sm" id="import-btn">Import</button>',
          '<span id="import-msg" class="muted"></span>',
        '</div>',
        '<p class="hint">',
          'Subscription URLs are fetched server-side; single links are validated with',
          ' xray -test before saving.',
        '</p>',
      '</div>'
    ].join('');

    document.getElementById('xray-start').addEventListener('click', xrayStart);
    document.getElementById('xray-stop').addEventListener('click', xrayStop);
    document.getElementById('rm-tun0').addEventListener('click', function () { setRouteMode('tun0'); });
    document.getElementById('rm-tproxy').addEventListener('click', function () { setRouteMode('tproxy'); });
    document.getElementById('prof-probe').addEventListener('click', probeSpeeds);
    document.getElementById('prof-refresh').addEventListener('click', loadProfiles);
    document.getElementById('import-btn').addEventListener('click', doImport);
  }

  async function loadXray() {
    await Promise.all([loadXrayStatus(), loadProfiles()]);
  }

  async function loadXrayStatus() {
    var r = await api('xray_status');
    if (!r) return;
    var pill = document.getElementById('xray-pill');
    var kvs  = document.getElementById('xray-stat-kvs');
    if (r.ok) {
      if (pill) {
        pill.textContent = r.running ? 'Running' : 'Stopped';  // XSS-safe
        pill.className   = 'pill ' + (r.running ? 'ok' : 'danger');
      }
      if (kvs) {
        kvs.textContent = '';
        // All values from server passed through kv() → textContent — XSS-safe
        if (r.mode != null)         kvs.appendChild(kv('Mode',    r.mode));
        if (r.listen != null)       kvs.appendChild(kv('Listen',  ':' + r.listen));
        kvs.appendChild(kv('VPN gateway', r.vpn_gateway ? 'yes' : 'no'));
        if (r.pid && r.pid > 0)     kvs.appendChild(kv('PID',     r.pid));
      }
      // Highlight active mode button
      ['tun0', 'tproxy'].forEach(function (m) {
        var b = document.getElementById('rm-' + m);
        if (b) b.className = 'btn sm' + (r.mode === m ? ' primary' : '');
      });
      var rp = document.getElementById('route-pill');
      if (rp) rp.textContent = r.mode || '—';  // XSS-safe
    } else {
      if (pill) { pill.textContent = 'Error'; pill.className = 'pill danger'; }
    }
  }

  async function loadProfiles() {
    var r  = await api('prof_list');
    var el = document.getElementById('prof-list');
    if (!el) return;
    el.textContent = '';

    if (!r || !r.ok) {
      el.appendChild(mkEl('div', 'empty muted', 'Failed to load profiles'));
      return;
    }

    var profiles = r.profiles || [];
    if (!profiles.length) {
      el.appendChild(mkEl('div', 'empty muted', 'No profiles. Import one below.'));
      return;
    }

    profiles.forEach(function (p) {
      var item = mkEl('div', 'prof-item' + (p.active ? ' active-prof' : ''));

      // Profile name — server-provided — textContent only (XSS-safe)
      var nameEl = mkEl('span', 'prof-name');
      nameEl.textContent = p.name;  // XSS-safe

      // Protocol/server sub-line — server-provided — textContent only
      var subEl = mkEl('span', 'prof-sub');
      subEl.textContent = (p.protocol || '?') + ' · ' + (p.server || '?') + ':' + (p.port || '?');  // XSS-safe

      item.appendChild(nameEl);
      item.appendChild(subEl);

      if (p.active) {
        item.appendChild(mkEl('span', 'pill ok', 'active'));
      } else {
        var sw = mkEl('button', 'btn sm primary', 'Switch');
        // Closure to capture p.name correctly
        (function (name) {
          sw.addEventListener('click', function () { switchProfile(name); });
        }(p.name));
        item.appendChild(sw);
      }

      el.appendChild(item);
    });
  }

  async function switchProfile(name) {
    var r = await api('prof_switch', name);
    if (r && r.ok) {
      toast('Switched to ' + name, 'ok');  // name is from our own profile list, not echoed from server
      loadProfiles();
    } else {
      toast((r && r.err) || 'Switch failed', 'err');
    }
  }

  async function xrayStart() {
    var r = await api('xray_start');
    toast(r && r.ok ? 'Xray started' : (r && r.err) || 'Start failed',
          r && r.ok ? 'ok' : 'err');
    if (activeTab === 'xray') loadXrayStatus();
  }

  async function xrayStop() {
    var r = await api('xray_stop');
    toast(r && r.ok ? 'Xray stopped' : (r && r.err) || 'Stop failed',
          r && r.ok ? 'ok' : 'err');
    if (activeTab === 'xray') loadXrayStatus();
  }

  async function setRouteMode(mode) {
    var r = await api('route_mode', mode);
    if (r && r.ok) {
      toast('Route mode: ' + mode, 'ok');
      loadXrayStatus();
    } else {
      toast((r && r.err) || 'Failed', 'err');
    }
  }

  async function doImport() {
    var val = document.getElementById('import-input').value.trim();
    if (!val) { toast('Enter a link or subscription URL', 'err'); return; }

    var btn = document.getElementById('import-btn');
    var msg = document.getElementById('import-msg');
    btn.disabled = true;
    msg.textContent = 'Importing…';  // XSS-safe

    var r;
    // http(s):// but not a proxy scheme → treat as subscription URL
    if (/^https?:\/\//i.test(val) && !/^(vmess|vless|trojan):\/\//i.test(val)) {
      r = await apiPost('prof_import_sub', val);
    } else {
      r = await apiPost('prof_import', val);
    }

    btn.disabled = false;
    msg.textContent = '';

    if (r && r.ok) {
      if (r.imported != null) {
        // Sub import: show counts
        toast('Imported: ' + r.imported + (r.failed ? ' · ' + r.failed + ' failed' : ''), 'ok', 5000);
      } else {
        // Single link import: r.name is the saved profile name
        toast('Imported: ' + (r.name || 'profile'), 'ok');
      }
      document.getElementById('import-input').value = '';
      loadProfiles();
    } else {
      toast((r && r.err) || 'Import failed', 'err', 5000);
    }
  }

  async function probeSpeeds() {
    var btn = document.getElementById('prof-probe');
    var el  = document.getElementById('probe-results');
    if (!btn || !el) return;

    btn.disabled = true;
    el.textContent = '';
    el.appendChild(mkEl('div', 'muted', 'Testing all profiles — this takes several seconds per profile…'));

    var r = await api('prof_probe_all');

    el.textContent = '';
    if (!r || !r.ok) {
      el.appendChild(mkEl('div', 'empty muted', (r && r.err) || 'Probe failed'));
      btn.disabled = false;
      return;
    }

    var results = r.results || [];
    if (!results.length) {
      el.appendChild(mkEl('div', 'empty muted', 'No profiles to probe'));
    }
    results.forEach(function (res) {
      var row = mkEl('div', 'kv');
      var nameEl = mkEl('span', 'k');
      // res.name is a profile name (server-provided) — textContent only — XSS-safe
      nameEl.textContent = (res.ok ? '🟢' : '🔴') + ' ' + (res.name || '?');
      var latEl = mkEl('span', 'v');
      // latency_ms is numeric; stringify — XSS-safe
      latEl.textContent = res.ok ? (res.latency_ms + ' ms') : 'unreachable';
      row.appendChild(nameEl);
      row.appendChild(latEl);
      el.appendChild(row);
    });

    if (r.fastest) {
      var fastest = r.fastest;  // profile name from server; used via textContent below — XSS-safe
      var sw = mkEl('button', 'btn sm primary');
      sw.textContent = '⚡ Switch to fastest (' + fastest + ')';  // XSS-safe — textContent
      sw.addEventListener('click', function () {
        switchProfile(fastest);
      });
      el.appendChild(sw);
    }

    btn.disabled = false;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SMS
  // ─────────────────────────────────────────────────────────────────────────

  function buildSms() {
    document.getElementById('view-sms').innerHTML = [
      '<div class="card">',
        '<h3>Send SMS</h3>',
        '<div class="grid g2">',
          '<div class="field">',
            '<label for="sms-to">Recipient</label>',
            '<input type="text" id="sms-to" placeholder="+1234567890" autocomplete="tel">',
          '</div>',
          '<div></div>',
        '</div>',
        '<div class="field">',
          '<label for="sms-text">Message (max 140 chars)</label>',
          '<textarea id="sms-text" rows="3" placeholder="Message…" maxlength="140"></textarea>',
        '</div>',
        '<button class="btn primary sm" id="sms-send-btn">Send SMS</button>',
      '</div>',
      '<div class="card">',
        '<h3>Inbox <span class="spacer"></span>',
          '<button class="btn ghost sm" id="sms-refresh">&#8635; Refresh</button>',
        '</h3>',
        '<div id="sms-list"></div>',
      '</div>',
      '<div class="card">',
        '<h3>SMS Remote Control</h3>',
        '<div class="toggle-wrap">',
          '<label class="toggle">',
            '<input type="checkbox" id="smscmd-en">',
            '<div class="toggle-track"></div>',
            '<div class="toggle-thumb"></div>',
          '</label>',
          '<span>Enabled</span>',
        '</div>',
        '<div class="field" style="margin-top:12px">',
          '<label for="smscmd-sec">Secret keyword</label>',
          '<input type="text" id="smscmd-sec" placeholder="mysecret" autocomplete="off">',
        '</div>',
        '<div class="field">',
          '<label for="smscmd-allow">',
            'Allowed numbers (comma-separated; empty = any)',
          '</label>',
          '<input type="text" id="smscmd-allow" placeholder="+1234567890,+0987654321">',
        '</div>',
        '<div class="toggle-wrap">',
          '<label class="toggle">',
            '<input type="checkbox" id="smscmd-reply" checked>',
            '<div class="toggle-track"></div>',
            '<div class="toggle-thumb"></div>',
          '</label>',
          '<span>Send reply SMS after command</span>',
        '</div>',
        '<div class="row" style="margin-top:12px">',
          '<button class="btn primary sm" id="smscmd-save">Save Config</button>',
        '</div>',
      '</div>'
    ].join('');

    document.getElementById('sms-send-btn').addEventListener('click', sendSms);
    document.getElementById('sms-refresh').addEventListener('click', loadSmsList);
    document.getElementById('smscmd-save').addEventListener('click', saveSmsCmdConfig);
  }

  async function loadSms() {
    await Promise.all([loadSmsList(), loadSmsCmdConfig()]);
  }

  async function loadSmsList() {
    var el = document.getElementById('sms-list');
    if (!el) return;
    el.textContent = '';
    el.appendChild(mkEl('div', 'empty muted', 'Loading…'));

    var r = await api('sms_list', '30');
    el.textContent = '';

    if (!r || !r.ok) {
      el.appendChild(mkEl('div', 'empty muted', 'Failed to load messages'));
      return;
    }

    var msgs = r.messages || [];
    if (!msgs.length) {
      el.appendChild(mkEl('div', 'empty muted', 'Inbox is empty'));
      return;
    }

    msgs.forEach(function (m) {
      var item = mkEl('div', 'sms-item' + (m.read === 0 || m.read === '0' ? ' sms-unread' : ''));

      var meta = mkEl('div', 'sms-meta');
      var addr = mkEl('span', 'sms-addr');
      addr.textContent = m.address || '?';  // XSS-safe — server addr could contain HTML
      meta.appendChild(addr);

      if (m.date_ms) {
        var d = new Date(Number(m.date_ms));
        if (!isNaN(d.getTime())) {
          var dateStr = d.toLocaleDateString() + ' '
            + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
          var dateEl = mkEl('span', 'sms-date');
          dateEl.textContent = dateStr;  // XSS-safe
          meta.appendChild(dateEl);
        }
      }

      var body = document.createElement('div');
      body.className = 'sms-body';
      body.textContent = m.body || '';  // XSS-safe — SMS body is attacker-controlled

      item.appendChild(meta);
      item.appendChild(body);
      el.appendChild(item);
    });
  }

  async function sendSms() {
    var to   = document.getElementById('sms-to').value.trim();
    var text = document.getElementById('sms-text').value.trim();
    if (!to || !text) { toast('Enter recipient and message', 'err'); return; }
    var r = await api('sms_send', to, text);
    if (r && r.ok) {
      toast('SMS sent', 'ok');
      document.getElementById('sms-to').value = '';
      document.getElementById('sms-text').value = '';
    } else {
      toast((r && r.err) || 'Send failed', 'err');
    }
  }

  async function loadSmsCmdConfig() {
    var r = await api('smscmd_get');
    if (!r || !r.ok) return;
    // Field values are stored config strings — set via .value (XSS-safe for inputs)
    var en    = document.getElementById('smscmd-en');
    var sec   = document.getElementById('smscmd-sec');
    var allow = document.getElementById('smscmd-allow');
    var reply = document.getElementById('smscmd-reply');
    if (en)    en.checked    = r.SMS_ENABLED === '1' || r.SMS_ENABLED === 1;
    if (sec)   sec.value     = r.SMS_SECRET  || '';
    if (allow) allow.value   = r.SMS_ALLOW   || '';
    if (reply) reply.checked = r.SMS_REPLY === 'true' || r.SMS_REPLY === true;
  }

  async function saveSmsCmdConfig() {
    // Build the JSON payload that smscmd_set expects in $ARG
    var payload = JSON.stringify({
      SMS_ENABLED: document.getElementById('smscmd-en').checked    ? '1' : '0',
      SMS_SECRET:  document.getElementById('smscmd-sec').value,
      SMS_ALLOW:   document.getElementById('smscmd-allow').value,
      SMS_REPLY:   document.getElementById('smscmd-reply').checked ? 'true' : 'false'
    });
    // POST JSON: outer body = {verb, token, arg: "<json-string>"}
    // api.cgi decodes arg via jq -r '.arg'; action.sh re-parses it with jq
    var r = await apiPost('smscmd_set', payload);
    if (r && r.ok) toast('SMS control config saved', 'ok');
    else toast((r && r.err) || 'Save failed', 'err');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CELLULAR
  // ─────────────────────────────────────────────────────────────────────────

  function buildCellular() {
    document.getElementById('view-cellular').innerHTML = [
      '<div class="grid g2">',
        '<div class="card"><h3>Signal</h3><div id="cell-sig-kvs"></div></div>',
        '<div class="card"><h3>Cell Info</h3><div id="cell-info-kvs"></div></div>',
      '</div>'
    ].join('');
  }

  async function loadCellular() {
    if (activeTab !== 'cellular' || document.hidden) return;

    var results = await Promise.all([api('signal'), api('cellinfo')]);
    var sig = results[0], ci = results[1];

    var sigEl = document.getElementById('cell-sig-kvs');
    if (sig && sig.ok && sigEl) {
      sigEl.textContent = '';
      // All values via kv() → textContent — XSS-safe
      [
        ['CSQ',      sig.csq],
        ['RSSI',     sig.rssi_dbm != null ? sig.rssi_dbm + ' dBm' : null],
        ['RSRP idx', sig.rsrp || null],
        ['RSRQ idx', sig.rsrq || null]
      ].forEach(function (p) { sigEl.appendChild(kv(p[0], p[1])); });
    } else if (sigEl) {
      sigEl.textContent = '';
      sigEl.appendChild(mkEl('div', 'empty muted', 'Signal data unavailable'));
    }

    var ciEl = document.getElementById('cell-info-kvs');
    if (ci && ci.ok && ciEl) {
      ciEl.textContent = '';
      [
        ['Operator', ci.operator],
        ['Net type', ci.nettype],
        ['IMEI',     ci.imei],
        ['ICCID',    ci.iccid],
        ['IMSI',     ci.imsi]
      ].forEach(function (p) { ciEl.appendChild(kv(p[0], p[1])); });
    } else if (ciEl) {
      ciEl.textContent = '';
      ciEl.appendChild(mkEl('div', 'empty muted', 'Cell info unavailable'));
    }

    sched(loadCellular, 5000);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // INTEGRATIONS
  // ─────────────────────────────────────────────────────────────────────────

  function buildIntegrations() {
    document.getElementById('view-integrations').innerHTML = [
      '<div class="card">',
        '<h3>Adblock <span id="ab-pill" class="pill">—</span></h3>',
        '<div id="ab-kvs"></div>',
        '<div class="row" style="margin-top:12px">',
          '<button class="btn ok sm" id="ab-enable">Enable</button>',
          '<button class="btn danger sm" id="ab-disable">Disable</button>',
          '<button class="btn sm" id="ab-update">&#8635; Update Lists</button>',
        '</div>',
        '<p class="hint">DNS sinkhole via dnsmasq on 127.0.0.1:5354. Does NOT touch the stock resolver.</p>',
      '</div>',
      '<div class="grid g2">',
        '<div class="card"><h3>Tailscale <span id="ts-pill" class="pill">—</span></h3><div id="ts-kvs"></div></div>',
        '<div class="card"><h3>Tor <span id="tor-pill" class="pill">—</span></h3><div id="tor-kvs"></div></div>',
      '</div>',
      '<div class="card"><h3>SSH (Dropbear) <span id="ssh-pill" class="pill">—</span></h3><div id="ssh-kvs"></div></div>'
    ].join('');

    document.getElementById('ab-enable').addEventListener('click', function () { abAction('adblock_enable'); });
    document.getElementById('ab-disable').addEventListener('click', function () { abAction('adblock_disable'); });
    document.getElementById('ab-update').addEventListener('click', abUpdate);
  }

  async function loadIntegrations() {
    await Promise.all([
      loadAdblock(),
      loadIntg('tailscale', 'ts'),
      loadIntg('tor',       'tor'),
      loadIntg('ssh',       'ssh')
    ]);
  }

  async function loadAdblock() {
    var r    = await api('adblock_status');
    var pill = document.getElementById('ab-pill');
    var kvs  = document.getElementById('ab-kvs');
    if (!r || !r.ok) {
      if (pill) { pill.textContent = '?'; pill.className = 'pill'; }
      return;
    }
    if (pill) {
      pill.textContent = r.running ? 'Active' : (r.enabled ? 'Enabled (stopped)' : 'Disabled');  // XSS-safe
      pill.className = 'pill ' + (r.running ? 'ok' : (r.enabled ? 'warn' : ''));
    }
    if (kvs) {
      kvs.textContent = '';
      kvs.appendChild(kv('Enabled', r.enabled ? 'yes' : 'no'));
      kvs.appendChild(kv('Running', r.running ? 'yes' : 'no'));
      kvs.appendChild(kv('Domains', r.domains != null ? r.domains.toLocaleString() : null));
    }
  }

  async function abAction(verb) {
    var r = await api(verb);
    if (r && r.ok) { toast(verb.replace('adblock_', '') + ' ok', 'ok'); loadAdblock(); }
    else toast((r && r.err) || 'Failed', 'err');
  }

  async function abUpdate() {
    toast('Updating blocklists — this may take ~30 s', 'info', 4000);
    var r = await api('adblock_update');
    if (r && r.ok) {
      toast('Updated: ' + (r.domains != null ? r.domains.toLocaleString() : '?') + ' domains', 'ok', 5000);
    } else {
      toast((r && r.err) || 'Update failed', 'err');
    }
    loadAdblock();
  }

  async function loadIntg(verb, prefix) {
    var r    = await api(verb, 'status');
    var pill = document.getElementById(prefix + '-pill');
    var kvs  = document.getElementById(prefix + '-kvs');
    if (!r || !r.ok) {
      if (pill) { pill.textContent = '?'; pill.className = 'pill'; }
      return;
    }
    if (!r.installed) {
      if (pill) { pill.textContent = 'Not installed'; pill.className = 'pill'; }
      if (kvs)  kvs.textContent = '';
      return;
    }
    if (pill) {
      pill.textContent = r.running ? 'Running' : 'Stopped';  // XSS-safe
      pill.className   = 'pill ' + (r.running ? 'ok' : 'danger');
    }
    if (kvs) {
      kvs.textContent = '';
      // All values from server go through kv() → textContent — XSS-safe
      kvs.appendChild(kv('Running', r.running ? 'yes' : 'no'));
      if (r.ip)          kvs.appendChild(kv('IP',        r.ip));
      if (r.port)        kvs.appendChild(kv('Port',      r.port));
      if (r.bootstrap)   kvs.appendChild(kv('Bootstrap', r.bootstrap));
      if (r.mem_mb != null && r.mem_mb > 0)
                         kvs.appendChild(kv('Memory',    r.mem_mb + ' MB'));
      if (r.keys_present != null)
                         kvs.appendChild(kv('Keys',      r.keys_present ? 'present' : 'none'));
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SYSTEM
  // ─────────────────────────────────────────────────────────────────────────

  function buildSystem() {
    document.getElementById('view-system').innerHTML = [
      '<div class="card">',
        '<h3>Device Info</h3>',
        '<div id="sys-kvs"></div>',
      '</div>',
      '<div class="card">',
        '<h3>LAN Exposure</h3>',
        '<div class="toggle-wrap">',
          '<label class="toggle">',
            '<input type="checkbox" id="lan-expose">',
            '<div class="toggle-track"></div>',
            '<div class="toggle-thumb"></div>',
          '</label>',
          '<span>Expose on LAN (0.0.0.0:8088) with HTTP Basic Auth</span>',
        '</div>',
        '<p class="hint">',
          'Default: localhost only (127.0.0.1:8088). LAN mode also adds HTTP Basic Auth',
          ' as a second layer. Takes effect on next httpd restart.',
        '</p>',
        '<div class="row" style="margin-top:12px">',
          '<button class="btn primary sm" id="lan-save">Apply</button>',
        '</div>',
      '</div>',
      '<div class="card">',
        '<h3>Danger Zone</h3>',
        '<button class="btn danger" id="reboot-btn">Reboot Device</button>',
        '<p class="hint">Sends /system/bin/reboot to Android after a 2 s delay.</p>',
      '</div>'
    ].join('');

    document.getElementById('lan-save').addEventListener('click', function () {
      var v = document.getElementById('lan-expose').checked ? '1' : '0';
      setPanelLan(v);
    });
    document.getElementById('reboot-btn').addEventListener('click', reboot);
  }

  async function loadSystem() {
    var r = await api('status');
    var el = document.getElementById('sys-kvs');
    if (r && r.ok && el) {
      el.textContent = '';
      var up = Number(r.uptime_s) || 0;
      var h = Math.floor(up / 3600), m = Math.floor((up % 3600) / 60);
      // Server values through kv() → textContent — XSS-safe
      [
        ['Model',          r.model],
        ['Uptime',         h + 'h ' + m + 'm'],
        ['Module version', 'v0.1.0'],
        ['Temp',           r.temp_c != null ? r.temp_c + ' °C' : null],
        ['Load',           r.load1]
      ].forEach(function (p) { el.appendChild(kv(p[0], p[1])); });
    }

    // Read current lan_expose state
    var lanR = await api('panel_lan');
    var lanEl = document.getElementById('lan-expose');
    if (lanEl && lanR && lanR.ok) {
      lanEl.checked = lanR.lan_expose === 1 || lanR.lan_expose === '1';
    }
  }

  async function setPanelLan(val) {
    var r = await api('panel_lan', val);
    if (r && r.ok) {
      toast('LAN expose set to ' + val + '. Restart httpd to apply.', 'ok', 6000);
    } else {
      toast((r && r.err) || 'Failed', 'err');
      // Revert toggle to reflect actual state
      var lanEl = document.getElementById('lan-expose');
      if (lanEl) lanEl.checked = val === '0';
    }
  }

  async function reboot() {
    if (!confirm('Reboot the device? All connections will drop immediately.')) return;
    var r = await api('sys_reboot');
    if (r && r.ok) {
      toast('Rebooting in 2 s…', 'ok', 4000);
    } else {
      toast((r && r.err) || 'Reboot verb not available', 'err');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CLIENTS
  // ─────────────────────────────────────────────────────────────────────────

  function buildClients() {
    // Static scaffold only — no server data interpolated here
    document.getElementById('view-clients').innerHTML = [
      '<div class="card">',
        '<h3>Connected Clients <span class="spacer"></span>',
          '<button class="btn ghost sm" id="clients-refresh">&#8635; Refresh</button>',
        '</h3>',
        '<div id="clients-list"></div>',
      '</div>',
      '<div class="card">',
        '<h3>VPN Bypass</h3>',
        '<p class="hint">',
          'Bypassed clients skip the VPN tunnel and route directly to the internet.',
          ' Add a client here to exclude it from Xray proxying.',
        '</p>',
        '<div id="bypass-list"></div>',
      '</div>'
    ].join('');

    document.getElementById('clients-refresh').addEventListener('click', loadClients);
  }

  async function loadClients() {
    if (activeTab !== 'clients' || document.hidden) return;

    var listEl   = document.getElementById('clients-list');
    var bypassEl = document.getElementById('bypass-list');
    if (!listEl || !bypassEl) return;

    listEl.textContent   = '';
    bypassEl.textContent = '';
    listEl.appendChild(mkEl('div', 'muted', 'Loading…'));

    var results = await Promise.all([api('clients'), api('bypass_list')]);
    var cr = results[0], br = results[1];

    listEl.textContent   = '';
    bypassEl.textContent = '';

    // Build bypass lookup — bypass_list returns {bypass:[<ip>,...]}
    var bypassSet = {};
    var bypassIps = [];
    if (br && br.ok && Array.isArray(br.bypass)) {
      br.bypass.forEach(function (ip) { bypassSet[ip] = true; bypassIps.push(ip); });
    }

    // ── Connected clients ────────────────────────────────────────────────────
    // clients verb returns {ok:true, clients:[{ip,mac,hostname}]}
    // Defensive: also handle legacy {ok:true, client_count:N} shape.
    var connectedIps = {};
    if (!cr || !cr.ok) {
      listEl.appendChild(mkEl('div', 'empty muted', (cr && cr.err) || 'Failed to load clients'));
    } else if (Array.isArray(cr.clients)) {
      var clients = cr.clients;
      if (!clients.length) {
        listEl.appendChild(mkEl('div', 'empty muted', 'No connected clients'));
      }
      clients.forEach(function (c) {
        var ip       = String(c.ip       || '');
        var mac      = String(c.mac      || '');
        var hostname = String(c.hostname || '');
        if (ip) connectedIps[ip] = true;

        var bypassed = !!bypassSet[ip];

        var row = mkEl('div', 'kv');
        var info = mkEl('span', 'k');
        // ip, hostname, mac are attacker-influenced (LAN device sets its own name)
        // — always set via textContent, never innerHTML — XSS-safe
        var label = ip;
        if (hostname) label = hostname + ' (' + ip + ')';
        if (mac)      label = label + ' · ' + mac;
        info.textContent = label;  // XSS-safe

        var btnEl = mkEl('button', 'btn sm' + (bypassed ? ' danger' : ''));
        btnEl.textContent = bypassed ? 'Un-bypass' : 'Bypass';  // XSS-safe
        (function (theIp, wasBypassed) {
          btnEl.addEventListener('click', function () {
            api(wasBypassed ? 'bypass_del' : 'bypass_add', theIp).then(function (r) {
              if (r && r.ok) {
                // theIp came from the server clients list; display via toast (textContent internally)
                toast((wasBypassed ? 'Bypass removed: ' : 'Bypassed: ') + theIp, 'ok');
                loadClients();
              } else {
                toast((r && r.err) || 'Failed', 'err');
              }
            });
          });
        }(ip, bypassed));

        row.appendChild(info);
        row.appendChild(btnEl);
        listEl.appendChild(row);
      });
    } else {
      // Legacy shape: just show count
      var cnt = cr.client_count != null ? String(cr.client_count) : '?';
      listEl.appendChild(mkEl('div', 'muted', cnt + ' ARP client(s) detected — detailed list not available'));
    }

    // ── Bypass panel ─────────────────────────────────────────────────────────
    // Show any bypass IPs that are NOT currently connected (orphaned bypass entries)
    var offlineBypass = bypassIps.filter(function (ip) { return !connectedIps[ip]; });

    if (!bypassIps.length) {
      bypassEl.appendChild(mkEl('div', 'empty muted', 'No bypassed clients'));
    } else if (offlineBypass.length) {
      bypassEl.appendChild(mkEl('div', 'muted', 'Bypassed IPs not currently connected:'));
      offlineBypass.forEach(function (ip) {
        var row  = mkEl('div', 'kv');
        var ipEl = mkEl('span', 'k');
        ipEl.textContent = ip;  // XSS-safe — IP string from bypass.list
        var delBtn = mkEl('button', 'btn sm danger', 'Remove');
        (function (theIp) {
          delBtn.addEventListener('click', function () {
            api('bypass_del', theIp).then(function (r) {
              if (r && r.ok) {
                toast('Bypass removed: ' + theIp, 'ok');
                loadClients();
              } else {
                toast((r && r.err) || 'Failed', 'err');
              }
            });
          });
        }(ip));
        row.appendChild(ipEl);
        row.appendChild(delBtn);
        bypassEl.appendChild(row);
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // INIT
  // ─────────────────────────────────────────────────────────────────────────

  function init() {
    initToken();

    // Build all tab scaffolds (static HTML only, no server data yet)
    buildDash();
    buildXray();
    buildSms();
    buildCellular();
    buildClients();
    buildIntegrations();
    buildSystem();

    // Wire tab buttons
    TABS.forEach(function (t) {
      document.getElementById('tab-' + t).addEventListener('click', function () {
        switchTab(t);
      });
    });

    // Token overlay submit
    document.getElementById('token-submit').addEventListener('click', function () {
      var t = document.getElementById('token-input').value.trim();
      if (!t) { toast('Enter the panel token', 'err'); return; }
      TOKEN = t;
      document.getElementById('token-overlay').classList.remove('show');
      loadTab(activeTab);
    });
    document.getElementById('token-input').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') document.getElementById('token-submit').click();
    });

    // Start polling the default tab if we already have a token
    if (TOKEN) loadTab('dash');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
}());
