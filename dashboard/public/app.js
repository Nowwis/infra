/* Console dev — rendu du dashboard. Données via /api/metrics (poll).
   Rendu strictement par textContent/DOM (jamais innerHTML avec des données). */
(function () {
  'use strict';
  var POLL_MS = 3000;
  var q = '';                       // terme de recherche courant
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
    s = num(s); var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    if (d) return d + 'j ' + h + 'h'; if (h) return h + 'h ' + m + 'm'; return m + 'm';
  }
  function level(ratio, warn, crit) { return ratio >= crit ? 'lvl-crit' : ratio >= warn ? 'lvl-warn' : 'lvl-ok'; }
  function panel(id) { return document.getElementById(id); }
  function setCount(id, n) { var c = panel(id).querySelector('[data-count]'); if (c) c.textContent = n; }
  function setEmpty(id, on) { var e = panel(id).querySelector('[data-empty]'); if (e) e.hidden = !on; }

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
    var mt = num(sys.mem_total_kb), ma = num(sys.mem_avail_kb), mu = mt - ma;
    setVital('ram', mt ? mu / mt : 0, gib(mu) + ' / ' + gib(mt), level(mt ? mu / mt : 0, 0.8, 0.92));
    var st = num(sys.swap_total_kb), su = num(sys.swap_used_kb);
    setVital('swap', st ? su / st : 0, st ? (gib(su) + ' / ' + gib(st)) : '—', level(st ? su / st : 0, 0.6, 0.85));
    var nc = num(sys.ncpu) || 1, ld = num(sys.load1);
    setVital('cpu', ld / nc, 'charge ' + ld.toFixed(2) + ' / ' + nc, level(ld / nc, 0.7, 1.0));
    var root = (disks || []).filter(function (d) { return d.mount === '/'; })[0] || (disks || [])[0];
    if (root) {
      var up = num(root.use_pct) / 100;
      setVital('disk', up, bytes(num(root.used) * 1024) + ' / ' + bytes(num(root.size) * 1024), level(up, 0.8, 0.92));
    }
  }

  // --- groupes repliables (docker, sessions) ------------------------------
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
      var span = el('span'); span.appendChild(el('b', null, p[0])); span.appendChild(document.createTextNode(' ' + p[1]));
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

  // --- docker : groupé par projet -----------------------------------------
  function renderDocker(list) {
    setCount('docker', (list || []).length);
    setEmpty('docker', !(list || []).length);
    var groups = groupBy(list, function (c) { return c.project || c.name; }).map(function (g) {
      var cpu = g.items.reduce(function (a, c) { return a + num(c.cpu_pct); }, 0);
      g.meta = g.items.length + ' · ' + cpu.toFixed(1) + ' % CPU';
      return g;
    });
    renderGroups('docker', groups, function (c) {
      var r = el('div', 'row');
      var name = el('div', 'r-name'); name.appendChild(document.createTextNode(c.name || '—'));
      r.appendChild(name);
      r.appendChild(metricsCell([['cpu', pct(c.cpu_pct)], ['mem', (c.mem_used || '—')]]));
      r.dataset.search = ((c.name || '') + ' ' + (c.project || '')).toLowerCase();
      return r;
    });
  }

  // --- sessions Claude : loties par dossier -------------------------------
  function renderSessions(list) {
    setCount('sessions', (list || []).length);
    setEmpty('sessions', !(list || []).length);
    var groups = groupBy(list, function (s) { return s.group || s.name || '—'; }).map(function (g) {
      var rss = g.items.reduce(function (a, s) { return a + num(s.rss_kb); }, 0);
      g.meta = g.items.length + ' · ' + gib(rss);
      return g;
    });
    renderGroups('sessions', groups, function (s) {
      var r = el('div', 'row');
      var left = el('div', 'r-name');
      var kind = (s.kind === 'remote-control') ? 'rc' : (s.kind === 'sdk-backend') ? 'sdk' : '';
      var tag = el('span', 'tag' + (kind ? ' ' + kind : ''), s.kind || 'claude');
      left.appendChild(tag);
      left.appendChild(document.createTextNode(' pid ' + (s.pid != null ? s.pid : '—')));
      if (s.model) { var sub = el('span', 'r-sub'); sub.textContent = '  ' + s.model; left.appendChild(sub); }
      r.appendChild(left);
      r.appendChild(metricsCell([['rss', bytes(num(s.rss_kb) * 1024)], ['cpu', pct(s.cpu_pct)], ['âge', etime(s.etime_s)]]));
      r.dataset.search = ((s.group || '') + ' ' + (s.kind || '') + ' ' + (s.model || '') + ' ' + (s.cwd || '') + ' ' + (s.pid || '')).toLowerCase();
      return r;
    });
  }

  // --- worktrees ----------------------------------------------------------
  function renderWorktrees(list) {
    setCount('worktrees', (list || []).length);
    setEmpty('worktrees', !(list || []).length);
    var host = panel('worktrees').querySelector('[data-rows]');
    clear(host);
    (list || []).forEach(function (w) {
      var box = el('div', 'wt');
      box.dataset.search = ((w.project || '') + ' ' + (w.branch || '') + ' ' + (w.domain || '')).toLowerCase();
      var top = el('div', 'wt-top');
      top.appendChild(el('span', 'wt-name', w.project || '—'));
      if (w.domain) top.appendChild(el('span', 'wt-dom', w.domain));
      var act = el('div', 'wt-actions');
      if (w.domain) { var a = el('a', 'btn', 'Ouvrir'); a.href = 'https://' + w.domain; a.target = '_blank'; a.rel = 'noopener'; act.appendChild(a); }
      var del = el('button', 'btn danger', 'Supprimer');
      del.addEventListener('click', function () { destroy(w.project); });
      act.appendChild(del);
      top.appendChild(act);
      box.appendChild(top);
      var sub = el('div', 'wt-sub');
      if (w.branch) sub.appendChild(el('span', null, w.branch));
      sub.appendChild(el('span', null, 'disque ' + bytes(w.disk_bytes)));
      box.appendChild(sub);
      host.appendChild(box);
    });
  }

  // --- disque -------------------------------------------------------------
  function renderDisk(list) {
    setCount('disk', (list || []).length);
    var host = panel('disk').querySelector('[data-rows]');
    clear(host);
    (list || []).forEach(function (d) {
      var row = el('div', 'disk-row');
      row.dataset.search = (d.mount || '').toLowerCase();
      var top = el('div', 'disk-top');
      top.appendChild(el('span', 'path', d.mount || '—'));
      top.appendChild(el('span', 'figs', bytes(num(d.used) * 1024) + ' / ' + bytes(num(d.size) * 1024) + '  ·  ' + (d.use_pct || '')));
      row.appendChild(top);
      var up = num(d.use_pct) / 100;
      var m = el('div', 'meter ' + level(up, 0.8, 0.92)); var span = el('span'); span.style.width = Math.min(100, up * 100) + '%'; m.appendChild(span);
      row.appendChild(m);
      host.appendChild(row);
    });
  }

  // --- recherche ----------------------------------------------------------
  function applyFilter() {
    var t = q.trim().toLowerCase();
    // groupes (docker, sessions)
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
    // lignes simples (worktrees, disk)
    ['worktrees', 'disk'].forEach(function (id) {
      panel(id).querySelectorAll('[data-search]').forEach(function (r) {
        r.classList.toggle('hidden', !!t && (r.dataset.search || '').indexOf(t) < 0);
      });
    });
  }

  // --- actions ------------------------------------------------------------
  function destroy(project) {
    if (!project) return;
    if (!window.confirm('Supprimer le worktree-env « ' + project + ' » ?\n(docker down + drop DB + suppression du worktree)')) return;
    fetch('/api/worktrees/' + encodeURIComponent(project) + '/destroy', { method: 'POST' })
      .then(function (r) { if (!r.ok) alert('Échec de la suppression (' + r.status + ').'); })
      .catch(function () { alert('Échec réseau lors de la suppression.'); })
      .then(refresh);
  }

  // --- cycle --------------------------------------------------------------
  function setStatus(state, text) {
    var s = document.getElementById('status');
    s.className = 'status ' + state;
    document.getElementById('status-text').textContent = text;
  }
  function refresh() {
    return fetch('/api/metrics', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(function (data) {
        renderVitals(data.system, data.disk);
        renderDocker(data.docker);
        renderSessions(data.sessions);
        renderWorktrees(data.worktrees);
        renderDisk(data.disk);
        applyFilter();
        setStatus('live', 'actualisé à l’instant');
      })
      .catch(function () { setStatus('error', 'hors ligne — nouvelle tentative…'); });
  }

  document.getElementById('q').addEventListener('input', function (e) { q = e.target.value; applyFilter(); });
  refresh();
  setInterval(refresh, POLL_MS);
})();
