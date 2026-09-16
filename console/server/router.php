<?php
declare(strict_types=1);

require __DIR__ . '/api.php';

$uri = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
$uri = is_string($uri) && $uri !== '' ? $uri : '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($method === 'GET' && $uri === '/api/snapshot') {
    header('Content-Type: application/json');
    echo console_api_snapshot();
    return true;
}

if ($method === 'GET' && $uri === '/api/snapshot.csv') {
    header('Content-Type: text/csv');
    echo console_api_csv();
    return true;
}

// Fichiers statiques de console/public, protégés contre la traversée de chemin.
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
    // Laisse le serveur (php -S ou le vrai serveur web) servir le fichier.
    return false;
}

http_response_code(404);
echo 'not found';
return true;
