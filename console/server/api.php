<?php
declare(strict_types=1);

/** Chemin de l'instantané : CONSOLE_SNAPSHOT, sinon CONSOLE_STATE/snapshot.json, sinon ~/.local/state/console. */
function console_api_snapshot_path(): string
{
    $env = getenv('CONSOLE_SNAPSHOT');
    if ($env !== false && $env !== '') {
        return $env;
    }
    $state = getenv('CONSOLE_STATE');
    if ($state === false || $state === '') {
        $home = getenv('HOME');
        $state = ($home !== false && $home !== '' ? $home : '/tmp') . '/.local/state/console';
    }
    return $state . '/snapshot.json';
}

/** Réponse servie quand l'instantané est absent ou illisible (le collecteur ne tourne pas). */
function console_api_missing(): array
{
    return ['generated_at' => null, 'sections' => new stdClass(), 'missing' => true];
}

/**
 * L'instantané du collecteur, chaque section enrichie de son âge et de `stale`
 * (âge supérieur à trois fois sa cadence). Cette API ne lance aucune commande :
 * tout le travail est fait en tâche de fond par bin/console-collector.
 */
function console_api_snapshot(): string
{
    $raw = @file_get_contents(console_api_snapshot_path());
    $data = $raw === false ? null : json_decode($raw, true);
    if (!is_array($data) || !isset($data['sections']) || !is_array($data['sections'])) {
        return (string) json_encode(console_api_missing(), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }

    $now = time();
    foreach ($data['sections'] as $name => $section) {
        if (!is_array($section)) {
            unset($data['sections'][$name]);
            continue;
        }
        $cadence = (int) ($section['cadence'] ?? 0);
        $age = $now - (int) ($section['collected_at'] ?? 0);
        $data['sections'][$name]['age_s'] = $age;
        $data['sections'][$name]['stale'] = $cadence > 0 && $age > $cadence * 3;
    }
    $data['missing'] = false;

    return (string) json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

/**
 * Neutralise l'injection de formule : une cellule commençant par =, +, -, @, une
 * tabulation ou un retour chariot est préfixée d'une apostrophe pour rester inerte.
 */
function console_api_csv_safe_cell(string $value): string
{
    if ($value === '') {
        return $value;
    }

    return in_array($value[0], ['=', '+', '-', '@', "\t", "\r"], true) ? "'" . $value : $value;
}

/** Aplatit l'instantané en CSV (une ligne par élément de section). */
function console_api_csv(): string
{
    $decoded = json_decode(console_api_snapshot(), true);
    $sections = is_array($decoded) && isset($decoded['sections']) && is_array($decoded['sections'])
        ? $decoded['sections'] : [];
    $data = static function (string $name) use ($sections) {
        return $sections[$name]['data'] ?? null;
    };
    $str = static function ($v): string {
        return is_scalar($v) ? (string) $v : '';
    };

    $rows = [['section', 'key', 'value']];

    $system = $data('system');
    if (is_array($system)) {
        foreach ($system as $k => $v) {
            if (is_array($v)) {
                foreach ($v as $k2 => $v2) {
                    $rows[] = ['system', $k . '.' . $k2, $str($v2)];
                }
            } else {
                $rows[] = ['system', (string) $k, $str($v)];
            }
        }
    }

    $disk = $data('disk');
    if (is_array($disk)) {
        foreach ($disk as $d) {
            $rows[] = ['disk', $str($d['mount'] ?? ''), 'use_pct=' . $str($d['use_pct'] ?? '')];
        }
    }

    $docker = $data('docker');
    if (is_array($docker)) {
        foreach ($docker as $c) {
            $rows[] = ['docker', $str($c['name'] ?? ''),
                'project=' . $str($c['project'] ?? '') . ' state=' . $str($c['state'] ?? '')
                . ' cpu=' . $str($c['cpu_pct'] ?? '') . ' restarts=' . $str($c['restarts'] ?? '')];
        }
    }

    $sessions = $data('sessions');
    if (is_array($sessions) && isset($sessions['items']) && is_array($sessions['items'])) {
        foreach ($sessions['items'] as $s) {
            $rows[] = ['session', $str($s['session_id'] ?? ''),
                'project=' . $str($s['project'] ?? '') . ' rss_kb=' . $str($s['rss_kb'] ?? '')
                . ' ticket=' . $str($s['ticket'] ?? '')];
        }
    }

    $projects = $data('projects');
    if (is_array($projects)) {
        foreach ($projects as $p) {
            $rows[] = ['project', $str($p['name'] ?? ''),
                'state=' . $str($p['state'] ?? '') . ' ticket=' . $str($p['ticket'] ?? '')
                . ' dirty=' . $str($p['dirty'] ?? '')];
        }
    }

    $diagnostics = $data('diagnostics');
    if (is_array($diagnostics)) {
        foreach ($diagnostics as $d) {
            $rows[] = ['diagnostics', $str($d['id'] ?? ''),
                $str($d['level'] ?? '') . ' ' . $str($d['title'] ?? '')];
        }
    }

    $buf = fopen('php://temp', 'r+');
    foreach ($rows as $i => $row) {
        // L'en-tête est un littéral de confiance ; les données peuvent venir de noms
        // de conteneurs ou de points de montage, donc on neutralise les formules.
        fputcsv($buf, $i === 0 ? $row : array_map('console_api_csv_safe_cell', $row));
    }
    rewind($buf);
    $csv = stream_get_contents($buf);
    fclose($buf);

    return $csv === false ? '' : $csv;
}
