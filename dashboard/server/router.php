<?php
declare(strict_types=1);

require __DIR__ . '/api.php';

$uri = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
$uri = is_string($uri) && $uri !== '' ? $uri : '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($method === 'GET' && $uri === '/api/metrics') {
    header('Content-Type: application/json');
    echo wt_api_metrics();
    return true;
}

if ($method === 'GET' && $uri === '/api/metrics.csv') {
    header('Content-Type: text/csv');
    echo wt_api_csv();
    return true;
}

if ($method === 'POST' && preg_match('#^/api/worktrees/([^/]+)/destroy$#', $uri, $m)) {
    // destroy.php is created in Task 4; the require lives inside this branch
    // so it never runs (and can't break) plain metrics/static requests.
    require __DIR__ . '/destroy.php';
    header('Content-Type: application/json');
    echo wt_api_destroy($m[1]);
    return true;
}

// Static file serving from dashboard/public, guarded against path traversal.
$publicDir = realpath(dirname(__DIR__) . '/public');
if ($publicDir === false) {
    http_response_code(404);
    echo 'not found';
    return true;
}

$requested = $uri === '/' ? '/index.html' : $uri;
$candidate = realpath($publicDir . $requested);

$withinPublic = $candidate !== false
    && (
        $candidate === $publicDir
        || str_starts_with($candidate, $publicDir . DIRECTORY_SEPARATOR)
    );

if ($method === 'GET' && $withinPublic && is_file($candidate)) {
    // Let the built-in `php -S` server (or the real webserver) serve the file.
    return false;
}

http_response_code(404);
echo 'not found';
return true;
