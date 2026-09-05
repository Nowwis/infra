<?php
declare(strict_types=1);

/** Resolve the wt binary: WT_DASH_WT env, else <repo>/bin/wt. */
function wt_dash_wt(): string
{
    $env = getenv('WT_DASH_WT');
    return $env !== false && $env !== '' ? $env : dirname(__DIR__, 2) . '/bin/wt';
}

/**
 * Validated destroy: looks up $project in `wt list --json`; if it is not a
 * known project, refuses (404 + {ok:false}) without ever touching the shell
 * with the caller-supplied value. Only the registry-resolved app/slug for a
 * matched entry are passed to `wt destroy`, each via escapeshellarg.
 */
function wt_api_destroy(string $project): string
{
    $wt = wt_dash_wt();
    $list = json_decode((string) @shell_exec(escapeshellarg($wt) . ' list --json 2>/dev/null'), true);
    $list = is_array($list) ? $list : [];

    $match = null;
    foreach ($list as $entry) {
        if (is_array($entry) && ($entry['project'] ?? null) === $project) {
            $match = $entry;
            break;
        }
    }

    if ($match === null) {
        http_response_code(404);
        return json_encode(['ok' => false, 'error' => 'unknown project']);
    }

    $cmd = escapeshellarg($wt) . ' destroy '
        . escapeshellarg((string) $match['app']) . ' '
        . escapeshellarg((string) $match['slug']) . ' --yes 2>&1';
    $out = (string) @shell_exec($cmd);

    return json_encode(['ok' => true, 'output' => $out]);
}
