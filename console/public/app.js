/* Console dev — rendu en lecture seule de /api/snapshot (poll 2 s).
   La page ne lance aucune commande : tout vient du collecteur.
   Rendu strictement par textContent/DOM. */
(function () {
  'use strict';
  var POLL_MS = 2000;
  var q = '';                          // terme de recherche courant
  var collapsed = Object.create(null); // état de repli mémorisé par clé de groupe

  // --- helpers ------------------------------------------------------------
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = String(text);
    return n;
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }
  function num(v) { var f = parseFloat(v); return isFinite(f) ? f : 0; }
  function gib(kb) { return (num(kb) / 1048576).toFixed(1) + ' Go'; }
  function bytes(b) {
    b = num(b);
    if (b >= 1073741824) return (b / 1073741824).toFixed(1) + ' Go';
    if (b >= 1048576) return (b / 1048576).toFixed(0) + ' Mo';
    if (b >= 1024) return (b / 1024).toFixed(0) + ' Ko';
    return b + ' o';
  }
  function pct(v) { return (typeof v === 'string') ? v : (num(v).toFixed(1) + ' %'); }
  function etime(s) {
    s = num(s);
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    if (d) return d + 'j ' + h + 'h';
    if (h) return h + 'h ' + m + 'm';
    if (m) return m + 'm';
    return Math.max(0, Math.floor(s)) + 's';
  }
  function hhmm(ts) {
    var d = new Date(ts);
    return isNaN(d.getTime()) ? '—' :
      ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) + ':' + ('0' + d.getSeconds()).slice(-2);
  }
  function level(ratio, warn, crit) { return ratio >= crit ? 'lvl-crit' : ratio >= warn ? 'lvl-warn' : 'lvl-ok'; }
  function panel(id) { return document.getElementById(id); }
  function setCount(id, n) { var c = panel(id).querySelector('[data-count]'); if (c) c.textContent = n; }
  function setEmpty(id, on) { var e = panel(id).querySelector('[data-empty]'); if (e) e.hidden = !on; }
  function sectionOf(snap, name) { return (snap && snap.sections && snap.sections[name]) || null; }
  function dataOf(snap, name) { var s = sectionOf(snap, name); return s ? s.data : null; }

  // --- vitals -------------------------------------------------------------
  function setVital(k, ratio, value, lvl) {
    var v = document.querySelector('.vital[data-k="' + k + '"]');
    if (!v) return;
    v.className = 'vital ' + (lvl || level(ratio, 0.75, 0.9));
    v.querySelector('.meter > span').style.width = Math.max(0, Math.min(100, ratio * 100)) + '%';
    v.querySelector('.vital-v').textContent = value;
  }
  function renderVitals(sys, disks) {
    sys = sys || {};
    var psi = sys.psi || {};
    var mt = num(sys.mem_total_kb), ma = num(sys.mem_avail_kb), mu = mt - ma;
    setVital('ram', mt ? mu / mt : 0, gib(mu) + ' / ' + gib(mt), level(mt ? mu / mt : 0, 0.8, 0.92));
    var st = num(sys.swap_total_kb), su = num(sys.swap_used_kb);
    setVital('swap', st ? su / st : 0, st ? (gib(su) + ' / ' + gib(st)) : '—', level(st ? su / st : 0, 0.5, 0.8));
    var nc = num(sys.ncpu) || 1, ld = num(sys.load1);
    setVital('cpu', ld / nc, 'charge ' + ld.toFixed(2) + ' / ' + nc + '  ·  psi ' + num(psi.cpu_some_avg10).toFixed(1),
      level(ld / nc, 0.7, 1.0));
    var root = (disks || []).filter(function (d) { return d.mount === '/'; })[0] || (disks || [])[0];
    if (root) {
      var up = num(root.use_pct) / 100;
      setVital('disk', up, bytes(num(root.used) * 1024) + ' / ' + bytes(num(root.size) * 1024), level(up, 0.85, 0.95));
    }
  }

  // --- diagnostics --------------------------------------------------------
  function renderDiagnostics(list) {
    list = list || [];
    setCount('diagnostics', list.length);
    setEmpty('diagnostics', !list.length);
    var host = panel('diagnostics').querySelector('[data-rows]');
    clear(host);
    list.forEach(function (d) {
      var crit = d.level === 'crit';
      var row = el('div', 'diag ' + (crit ? 'lvl-crit' : 'lvl-warn'));
      var top = el('div', 'diag-top');
      top.appendChild(el('span', 'tag ' + (crit ? 'crit' : 'warn'), crit ? 'critique' : 'attention'));
      top.appendChild(el('span', 'diag-title', d.title || d.id || '—'));
      row.appendChild(top);
      if (d.detail) row.appendChild(el('div', 'diag-detail', d.detail));
      if (d.action) row.appendChild(el('div', 'diag-action', '→ ' + d.action));
      row.dataset.search = ((d.id || '') + ' ' + (d.title || '') + ' ' + (d.detail || '')).toLowerCase();
      host.appendChild(row);
    });
  }

  // --- projets ------------------------------------------------------------
  function renderProjects(list) {
    list = list || [];
    setCount('projects', list.length);
    setEmpty('projects', !list.length);
    var host = panel('projects').querySelector('[data-rows]');
    clear(host);
    list.forEach(function (p) {
      var row = el('div', 'proj');
      var top = el('div', 'proj-top');
      top.appendChild(el('span', 'proj-name', p.name || '—'));
      if (p.state === 'active') {
        top.appendChild(el('span', 'tag rc', p.ticket || 'ticket'));
        top.appendChild(el('span', 'r-sub', p.branch || ''));
        top.appendChild(el('span', 'r-sub',
          p.is_me ? 'cette session' : (p.owner_alive ? 'autre session' : 'session terminée')));
      } else {
        top.appendChild(el('span', 'tag', 'libre'));
      }
      row.appendChild(top);

      var meta = [];
      if (p.current_branch) meta.push('branche ' + p.current_branch);
      if (num(p.dirty) > 0) meta.push(num(p.dirty) + ' fichier(s) modifié(s)');
      if (num(p.untracked) > 0) meta.push(num(p.untracked) + ' non suivi(s)');
      (p.pending_prs || []).forEach(function (pr) {
        meta.push('PR ' + (pr.ticket || '') + (pr.parked ? ' (de côté)' : '') + (pr.gh_state ? ' · ' + pr.gh_state : ''));
      });
      (p.drift || []).forEach(function (d) { meta.push('⚠ ' + d); });
      if (meta.length) row.appendChild(el('div', 'proj-sub', meta.join('  ·  ')));
      row.dataset.search = ((p.name || '') + ' ' + (p.ticket || '') + ' ' + (p.current_branch || '')).toLowerCase();
      host.appendChild(row);
    });
  }

  // --- activité (journal des sessions) ------------------------------------
  var STATUS = {
    executing: { label: 'exécute', cls: 'st-exec' },
    waiting: { label: 'attend une réponse', cls: 'st-wait' },
    working: { label: 'travaille', cls: 'st-work' },
    idle: { label: 'au repos', cls: 'st-idle' },
    unknown: { label: '—', cls: 'st-idle' }
  };
  function statusOf(s) { return STATUS[s && s.status] || STATUS.unknown; }

  function renderActivity(list) {
    list = list || [];
    setCount('activity', list.length);
    setEmpty('activity', !list.length);
    var host = panel('activity').querySelector('[data-rows]');
    clear(host);
    list.slice(0, 80).forEach(function (e) {
      var blocked = e.event === 'guard.block';
      var row = el('div', 'act' + (blocked ? ' act-block' : ''));
      var top = el('div', 'act-top');
      top.appendChild(el('span', 'act-time', hhmm(e.ts)));
      top.appendChild(el('span', 'tag' + (blocked ? ' crit' : ''), blocked ? 'bloqué' : (e.tool || e.event)));
      if (e.project) top.appendChild(el('span', 'r-sub', e.project));
      if (e.result === 'error') top.appendChild(el('span', 'tag warn', 'erreur'));
      row.appendChild(top);
      if (e.summary) row.appendChild(el('div', 'act-sum', e.summary));
      row.dataset.search = ((e.project || '') + ' ' + (e.tool || '') + ' ' + (e.event || '') + ' '
        + (e.summary || '') + ' ' + (e.session || '')).toLowerCase();
      host.appendChild(row);
    });
  }

  // --- groupes repliables (sessions, docker) ------------------------------
  function groupBlock(key, name, meta) {
    var d = el('details', 'group'); d.dataset.key = key;
    d.open = !collapsed[key];
    d.addEventListener('toggle', function () { collapsed[key] = !d.open; });
    var s = el('summary');
    s.appendChild(el('span', 'g-name', name));
    if (meta) s.appendChild(el('span', 'g-meta', meta));
    d.appendChild(s);
    var body = el('div', 'g-body'); d.appendChild(body);
    d._body = body; d._search = (name || '').toLowerCase();
    return d;
  }
  function groupBy(list, keyFn) {
    var m = Object.create(null), order = [];
    (list || []).forEach(function (x) {
      var k = keyFn(x) || '—';
      if (!m[k]) { m[k] = []; order.push(k); }
      m[k].push(x);
    });
    order.sort(function (a, b) { return m[b].length - m[a].length || a.localeCompare(b); });
    return order.map(function (k) { return { key: k, items: m[k] }; });
  }
  function metricsCell(pairs) {
    var box = el('div', 'metrics');
    pairs.forEach(function (p) {
      var span = el('span');
      span.appendChild(el('b', null, p[0]));
      span.appendChild(document.createTextNode(' ' + p[1]));
      box.appendChild(span);
    });
    return box;
  }
  function renderGroups(id, groups, rowFn) {
    var host = panel(id).querySelector('[data-groups]');
    clear(host);
    groups.forEach(function (g) {
      var block = groupBlock(id + ':' + g.key, g.key, g.meta);
      g.items.forEach(function (it) {
        var r = rowFn(it);
        r._search = (block._search + ' ' + (r.dataset.search || '')).trim();
        block._body.appendChild(r);
      });
      host.appendChild(block);
    });
  }

  // --- sessions Claude ----------------------------------------------------
  function renderSessions(sessions) {
    var items = (sessions && sessions.items) || [];
    setCount('sessions', items.length);
    setEmpty('sessions', !items.length);
    var groups = groupBy(items, function (s) { return s.system ? 'système' : (s.project || s.tmux || '—'); })
      .map(function (g) {
        var rss = g.items.reduce(function (a, s) { return a + num(s.rss_kb); }, 0);
        var busy = g.items.filter(function (s) { return s.status === 'executing' || s.status === 'waiting'; }).length;
        g.meta = g.items.length + (busy ? ' · ' + busy + ' actives' : '') + ' · ' + gib(rss);
        return g;
      });
    renderGroups('sessions', groups, function (s) {
      var st = statusOf(s);
      var r = el('div', 'row');
      var left = el('div', 'r-name');
      left.appendChild(el('span', 'tag ' + st.cls, st.label));
      if (s.ticket) left.appendChild(el('span', 'tag rc', s.ticket));
      left.appendChild(document.createTextNode(' ' + (s.tmux || s.name || ('pid ' + (s.pid != null ? s.pid : '—')))));
      if (s.status_detail) {
        var sub = el('span', 'r-sub');
        sub.textContent = '  ' + s.status_detail + (s.status_since_s != null ? ' · ' + etime(s.status_since_s) : '');
        left.appendChild(sub);
      }
      if (s.last_block) left.appendChild(el('span', 'tag crit', 'bloquée'));
      r.appendChild(left);
      r.appendChild(metricsCell([
        ['ram', bytes(num(s.rss_kb) * 1024)],
        ['âge', etime(s.age_s)],
        ['mcp', (s.mcp || []).length]
      ]));
      r.dataset.search = ((s.project || '') + ' ' + (s.tmux || '') + ' ' + (s.name || '') + ' '
        + (s.cwd || '') + ' ' + (s.ticket || '') + ' ' + (s.status || '') + ' ' + (s.pid || '')).toLowerCase();
      return r;
    });
  }

  // --- docker -------------------------------------------------------------
  function renderDocker(list) {
    list = list || [];
    setCount('docker', list.length);
    setEmpty('docker', !list.length);
    var groups = groupBy(list, function (c) { return c.project || c.name; }).map(function (g) {
      var cpu = g.items.reduce(function (a, c) { return a + num(c.cpu_pct); }, 0);
      var up = g.items.filter(function (c) { return c.state === 'running'; }).length;
      g.meta = up + '/' + g.items.length + ' · ' + cpu.toFixed(1) + ' % CPU';
      return g;
    });
    renderGroups('docker', groups, function (c) {
      var r = el('div', 'row' + (c.state === 'running' ? '' : ' off'));
      var name = el('div', 'r-name');
      name.appendChild(document.createTextNode(c.name || '—'));
      if (c.health && c.health !== 'healthy') name.appendChild(el('span', 'tag crit', c.health));
      if (num(c.restarts) > 0) name.appendChild(el('span', 'tag warn', 'restarts ' + num(c.restarts)));
      r.appendChild(name);
      r.appendChild(metricsCell([
        ['cpu', c.state === 'running' ? pct(c.cpu_pct) : '—'],
        ['mem', c.mem_used || '—'],
        ['état', c.state || '—']
      ]));
      r.dataset.search = ((c.name || '') + ' ' + (c.project || '') + ' ' + (c.state || '')).toLowerCase();
      return r;
    });
  }

  // --- disque -------------------------------------------------------------
  function renderDisk(list) {
    list = list || [];
    setCount('disk', list.length);
    var host = panel('disk').querySelector('[data-rows]');
    clear(host);
    list.forEach(function (d) {
      var row = el('div', 'disk-row');
      row.dataset.search = (d.mount || '').toLowerCase();
      var top = el('div', 'disk-top');
      top.appendChild(el('span', 'path', d.mount || '—'));
      top.appendChild(el('span', 'figs', bytes(num(d.used) * 1024) + ' / ' + bytes(num(d.size) * 1024)
        + '  ·  ' + num(d.use_pct) + ' %'));
      row.appendChild(top);
      var up = num(d.use_pct) / 100;
      var m = el('div', 'meter ' + level(up, 0.85, 0.95));
      var span = el('span'); span.style.width = Math.min(100, up * 100) + '%';
      m.appendChild(span);
      row.appendChild(m);
      host.appendChild(row);
    });
  }

  // --- recherche ----------------------------------------------------------
  function applyFilter() {
    var t = q.trim().toLowerCase();
    ['docker', 'sessions'].forEach(function (id) {
      panel(id).querySelectorAll('.group').forEach(function (g) {
        var gname = g.dataset.key.split(':').slice(1).join(':').toLowerCase();
        var gmatch = !t || gname.indexOf(t) >= 0;
        var vis = 0;
        g.querySelectorAll('.row').forEach(function (r) {
          var show = !t || gmatch || (r._search || '').indexOf(t) >= 0;
          r.classList.toggle('hidden', !show); if (show) vis++;
        });
        g.classList.toggle('hidden', vis === 0 && !gmatch);
        if (t && vis > 0) g.open = true;
      });
    });
    ['diagnostics', 'projects', 'activity', 'disk'].forEach(function (id) {
      panel(id).querySelectorAll('[data-search]').forEach(function (r) {
        r.classList.toggle('hidden', !!t && (r.dataset.search || '').indexOf(t) < 0);
      });
    });
  }

  // --- cycle --------------------------------------------------------------
  function setStatus(state, text) {
    var s = document.getElementById('status');
    s.className = 'status ' + state;
    document.getElementById('status-text').textContent = text;
  }
  function staleNames(snap) {
    var names = [];
    Object.keys((snap && snap.sections) || {}).forEach(function (n) {
      if (snap.sections[n] && snap.sections[n].stale) names.push(n);
    });
    return names;
  }
  function refresh() {
    return fetch('/api/snapshot', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(function (snap) {
        if (snap.missing) {
          setStatus('error', 'aucun instantané — le collecteur ne tourne pas');
        } else {
          var stale = staleNames(snap);
          if (stale.length) setStatus('stale', 'données périmées : ' + stale.join(', '));
          else setStatus('live', 'actualisé à l’instant');
        }
        renderVitals(dataOf(snap, 'system'), dataOf(snap, 'disk'));
        renderDiagnostics(dataOf(snap, 'diagnostics'));
        renderProjects(dataOf(snap, 'projects'));
        renderActivity(dataOf(snap, 'activity'));
        renderSessions(dataOf(snap, 'sessions'));
        renderDocker(dataOf(snap, 'docker'));
        renderDisk(dataOf(snap, 'disk'));
        applyFilter();
      })
      .catch(function () { setStatus('error', 'hors ligne — nouvelle tentative…'); });
  }

  document.getElementById('q').addEventListener('input', function (e) { q = e.target.value; applyFilter(); });
  refresh();
  setInterval(refresh, POLL_MS);
})();
