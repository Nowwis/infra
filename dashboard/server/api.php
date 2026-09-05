<?php
declare(strict_types=1);

/** Resolve the wt-metrics binary: WT_METRICS_BIN env, else <repo>/bin/wt-metrics. */
function wt_metrics_bin(): string
{
    $env = getenv('WT_METRICS_BIN');
    return $env !== false && $env !== '' ? $env : dirname(__DIR__, 2) . '/bin/wt-metrics';
}

/** Resolve the cache file path: WT_DASH_CACHE env, else a temp path. */
function wt_dash_cache_path(): string
{
    $env = getenv('WT_DASH_CACHE');
    return $env !== false && $env !== '' ? $env : sys_get_temp_dir() . '/wt-dash-metrics.json';
}

/** The safe default payload used whenever wt-metrics is unavailable or emits invalid output. */
function wt_api_metrics_default(): string
{
    return '{"system":{},"disk":[],"docker":[],"worktrees":[],"sessions":[]}';
}

/**
 * Aggregated dashboard metrics as a JSON string.
 * Runs `wt-metrics all`, cached to a file for ~2s to avoid re-shelling on
 * every request. On invalid, empty, or failing output, falls back to a safe
 * default JSON object carrying all five expected keys.
 */
function wt_api_metrics(): string
{
    $cache = wt_dash_cache_path();
    if (is_file($cache) && (time() - (int) @filemtime($cache)) < 2) {
        $cached = @file_get_contents($cache);
        if ($cached !== false && $cached !== '' && json_decode($cached) !== null) {
            return $cached;
        }
    }

    $bin = wt_metrics_bin();
    $out = @shell_exec(escapeshellarg($bin) . ' all 2>/dev/null');

    if ($out === null || trim((string) $out) === '' || json_decode((string) $out) === null) {
        $out = wt_api_metrics_default();
    }

    @file_put_contents($cache, $out);
    return $out;
}

/** Flatten the aggregated metrics into a CSV string (header row + data rows). */
function wt_api_csv(): string
{
    $decoded = json_decode(wt_api_metrics(), true);
    $metrics = is_array($decoded) ? $decoded : [];

    $rows = [['section', 'key', 'value']];

    $system = $metrics['system'] ?? [];
    if (is_array($system)) {
        foreach ($system as $k => $v) {
            $rows[] = ['system', (string) $k, is_scalar($v) ? (string) $v : json_encode($v)];
        }
    }

    $disk = $metrics['disk'] ?? [];
    if (is_array($disk)) {
        foreach ($disk as $d) {
            $mount = is_array($d) ? ($d['mount'] ?? '') : '';
            $usePct = is_array($d) ? ($d['use_pct'] ?? '') : '';
            $rows[] = ['disk', (string) $mount, 'use_pct=' . (string) $usePct];
        }
    }

    $docker = $metrics['docker'] ?? [];
    if (is_array($docker)) {
        foreach ($docker as $c) {
            $name = is_array($c) ? ($c['name'] ?? '') : '';
            $cpu = is_array($c) ? ($c['cpu_pct'] ?? '') : '';
            $rows[] = ['docker', (string) $name, 'cpu_pct=' . (string) $cpu];
        }
    }

    $worktrees = $metrics['worktrees'] ?? [];
    if (is_array($worktrees)) {
        foreach ($worktrees as $w) {
            $project = is_array($w) ? ($w['project'] ?? '') : '';
            $disk_bytes = is_array($w) ? ($w['disk_bytes'] ?? '') : '';
            $rows[] = ['worktree', (string) $project, 'disk_bytes=' . (string) $disk_bytes];
        }
    }

    $sessions = $metrics['sessions'] ?? [];
    if (is_array($sessions)) {
        foreach ($sessions as $s) {
            $pid = is_array($s) ? ($s['pid'] ?? '') : '';
            $kind = is_array($s) ? ($s['kind'] ?? '') : '';
            $rss = is_array($s) ? ($s['rss_kb'] ?? '') : '';
            $rows[] = ['session', (string) $pid, (string) $kind . ' rss=' . (string) $rss];
        }
    }

    $buf = fopen('php://temp', 'r+');
    foreach ($rows as $row) {
        fputcsv($buf, $row);
    }
    rewind($buf);
    $csv = stream_get_contents($buf);
    fclose($buf);

    return $csv === false ? '' : $csv;
}
