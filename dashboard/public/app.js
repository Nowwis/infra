(function () {
  'use strict';

  var POLL_MS = 3000;
  var HISTORY_LEN = 40;

  /** In-memory ring buffers for the tiny sparklines (never persisted, never sent anywhere). */
  var history = {
    mem: [],
    swap: [],
    load: []
  };

  function pushHistory(key, value) {
    var buf = history[key];
    buf.push(typeof value === 'number' && isFinite(value) ? value : 0);
    if (buf.length > HISTORY_LEN) buf.shift();
  }

  function clearChildren(el) {
    while (el.firstChild) el.removeChild(el.firstChild);
  }

  function el(tag, opts) {
    var node = document.createElement(tag);
    opts = opts || {};
    if (opts.className) node.className = opts.className;
    if (opts.text !== undefined) node.textContent = opts.text;
    return node;
  }

  function fmtBytesKb(kb) {
    if (typeof kb !== 'number' || !isFinite(kb)) return '—';
    var bytes = kb * 1024;
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++; }
    return bytes.toFixed(bytes >= 10 || i === 0 ? 0 : 1) + ' ' + units[i];
  }

  function fmtBytes(bytes) {
    if (typeof bytes !== 'number' || !isFinite(bytes)) return '—';
    return fmtBytesKb(bytes / 1024);
  }

  function fmtPct(v, digits) {
    if (typeof v !== 'number' || !isFinite(v)) return '—';
    return v.toFixed(digits === undefined ? 1 : digits) + '%';
  }

  function fmtEtime(seconds) {
    if (typeof seconds !== 'number' || !isFinite(seconds)) return '—';
    var s = Math.max(0, Math.floor(seconds));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var sec = s % 60;
    var parts = [];
    if (h) parts.push(h + 'h');
    if (h || m) parts.push(m + 'm');
    parts.push(sec + 's');
    return parts.join(' ');
  }

  function gaugeClassForPct(pct) {
    if (pct >= 90) return 'crit';
    if (pct >= 70) return 'warn';
    return '';
  }

  function buildSparkline(values, width, height) {
    var canvas = document.createElement('canvas');
    canvas.className = 'sparkline';
    canvas.width = width;
    canvas.height = height;
    var ctx = canvas.getContext('2d');
    if (!ctx || values.length < 2) return canvas;

    var max = Math.max.apply(null, values.concat([1]));
    var min = Math.min.apply(null, values.concat([0]));
    var range = max - min || 1;

    ctx.strokeStyle = getComputedStyle(document.documentElement)
      .getPropertyValue('--accent').trim() || '#2563eb';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    values.forEach(function (v, i) {
      var x = (i / (values.length - 1)) * width;
      var y = height - ((v - min) / range) * height;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.stroke();
    return canvas;
  }

  function buildGauge(label, pct, detail, sparkValues) {
    var wrap = el('div', { className: 'gauge' });

    var labelRow = el('div', { className: 'gauge-label' });
    labelRow.appendChild(el('span', { text: label }));
    labelRow.appendChild(el('span', { text: detail }));
    wrap.appendChild(labelRow);

    var track = el('div', { className: 'gauge-track' });
    var fill = el('div', { className: 'gauge-fill ' + gaugeClassForPct(pct) });
    var clamped = Math.max(0, Math.min(100, isFinite(pct) ? pct : 0));
    fill.style.width = clamped + '%';
    track.appendChild(fill);
    wrap.appendChild(track);

    if (sparkValues && sparkValues.length > 1) {
      wrap.appendChild(buildSparkline(sparkValues, 160, 24));
    }

    return wrap;
  }

  function renderSystem(system) {
    var container = document.getElementById('system-gauges');
    clearChildren(container);
    system = system || {};

    var memTotal = system.mem_total_kb;
    var memAvail = system.mem_avail_kb;
    var memUsedPct = (typeof memTotal === 'number' && memTotal > 0 && typeof memAvail === 'number')
      ? ((memTotal - memAvail) / memTotal) * 100
      : NaN;
    pushHistory('mem', memUsedPct);
    container.appendChild(buildGauge(
      'RAM',
      memUsedPct,
      fmtBytesKb(memTotal - memAvail) + ' / ' + fmtBytesKb(memTotal),
      history.mem
    ));

    var swapTotal = system.swap_total_kb;
    var swapUsed = system.swap_used_kb;
    var swapPct = (typeof swapTotal === 'number' && swapTotal > 0 && typeof swapUsed === 'number')
      ? (swapUsed / swapTotal) * 100
      : 0;
    pushHistory('swap', swapPct);
    container.appendChild(buildGauge(
      'Swap',
      swapPct,
      fmtBytesKb(swapUsed) + ' / ' + fmtBytesKb(swapTotal),
      history.swap
    ));

    var load1 = system.load1;
    var ncpu = system.ncpu;
    var loadPct = (typeof load1 === 'number' && typeof ncpu === 'number' && ncpu > 0)
      ? (load1 / ncpu) * 100
      : NaN;
    pushHistory('load', loadPct);
    container.appendChild(buildGauge(
      'CPU (load1)',
      loadPct,
      (typeof load1 === 'number' ? load1.toFixed(2) : '—') + ' / ' + (ncpu || '—') + ' cœurs',
      history.load
    ));
  }

  function setRow(tbody, cells) {
    var tr = document.createElement('tr');
    cells.forEach(function (c) {
      var td = document.createElement('td');
      if (c instanceof Node) td.appendChild(c);
      else td.textContent = c === undefined || c === null ? '—' : String(c);
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  }

  function emptyRow(tbody, colspan, text) {
    var tr = document.createElement('tr');
    tr.className = 'empty-row';
    var td = document.createElement('td');
    td.colSpan = colspan;
    td.textContent = text;
    tr.appendChild(td);
    tbody.appendChild(tr);
  }

  function renderDocker(list) {
    var tbody = document.querySelector('#docker-table tbody');
    clearChildren(tbody);
    list = Array.isArray(list) ? list : [];
    if (list.length === 0) { emptyRow(tbody, 5, 'Aucun container'); return; }
    list.forEach(function (c) {
      setRow(tbody, [
        c.name,
        c.project,
        typeof c.cpu_pct === 'string' ? c.cpu_pct : fmtPct(c.cpu_pct),
        c.mem_used,
        typeof c.mem_pct === 'string' ? c.mem_pct : fmtPct(c.mem_pct)
      ]);
    });
  }

  function renderSessions(list) {
    var tbody = document.querySelector('#sessions-table tbody');
    clearChildren(tbody);
    list = Array.isArray(list) ? list : [];
    if (list.length === 0) { emptyRow(tbody, 6, 'Aucune session'); return; }
    list.forEach(function (s) {
      setRow(tbody, [
        s.pid,
        s.kind,
        s.model || '—',
        fmtBytesKb(s.rss_kb),
        fmtPct(s.cpu_pct),
        fmtEtime(s.etime_s)
      ]);
    });
  }

  function renderDisk(list) {
    var tbody = document.querySelector('#disk-table tbody');
    clearChildren(tbody);
    list = Array.isArray(list) ? list : [];
    if (list.length === 0) { emptyRow(tbody, 5, 'Aucune donnée disque'); return; }
    list.forEach(function (d) {
      setRow(tbody, [
        d.mount,
        fmtBytesKb(d.size),
        fmtBytesKb(d.used),
        fmtBytesKb(d.avail),
        d.use_pct
      ]);
    });
  }

  function destroyWorktree(project) {
    var ok = window.confirm(
      'Supprimer définitivement le worktree "' + project + '" ? Cette action est irréversible.'
    );
    if (!ok) return;

    fetch('/api/worktrees/' + encodeURIComponent(project) + '/destroy', { method: 'POST' })
      .catch(function () { /* network error: refresh() below will still show current state */ })
      .then(function () { refresh(); });
  }

  function renderWorktrees(list) {
    var tbody = document.querySelector('#worktrees-table tbody');
    clearChildren(tbody);
    list = Array.isArray(list) ? list : [];
    if (list.length === 0) { emptyRow(tbody, 5, 'Aucun worktree'); return; }

    list.forEach(function (w) {
      var project = w.project;
      var domain = w.domain;

      var actions = el('div', { className: 'actions-cell' });

      if (domain) {
        var openLink = el('a', { className: 'btn', text: 'Ouvrir' });
        openLink.href = 'https://' + domain;
        openLink.target = '_blank';
        openLink.rel = 'noopener noreferrer';
        actions.appendChild(openLink);
      }

      var destroyBtn = el('button', { className: 'btn danger', text: 'Supprimer' });
      destroyBtn.type = 'button';
      destroyBtn.addEventListener('click', function () { destroyWorktree(project); });
      actions.appendChild(destroyBtn);

      setRow(tbody, [
        project,
        w.branch,
        domain,
        fmtBytes(w.disk_bytes),
        actions
      ]);
    });
  }

  function setLastUpdate() {
    var stamp = document.getElementById('last-update');
    if (!stamp) return;
    var now = new Date();
    stamp.textContent = 'MAJ ' + now.toLocaleTimeString();
  }

  function setExportLink() {
    var link = document.getElementById('export-csv');
    if (link) link.href = '/api/metrics.csv';
  }

  async function refresh() {
    try {
      var res = await fetch('/api/metrics', { cache: 'no-store' });
      if (!res.ok) throw new Error('bad status ' + res.status);
      var data = await res.json();

      renderSystem(data.system);
      renderDocker(data.docker);
      renderWorktrees(data.worktrees);
      renderSessions(data.sessions);
      renderDisk(data.disk);
      setLastUpdate();
    } catch (err) {
      var stamp = document.getElementById('last-update');
      if (stamp) stamp.textContent = 'Erreur de chargement';
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    setExportLink();
    refresh();
    setInterval(refresh, POLL_MS);
  });
})();
