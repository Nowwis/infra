<?php
/**
 * WordPress local configuration (Docker stack on the shared socle).
 * `make wp-config` copies it to /wp-config.php (ignored by git).
 *
 * LOCAL ONLY. The server's wp-config.php is never versioned nor deployed.
 * Every setting comes from the php container environment, i.e. from .docker/.env
 * (see the WordPress section of .docker/.env.example).
 */

$env = static function (string $name, string $default = ''): string {
	$value = getenv($name);
	return (false === $value || '' === $value) ? $default : $value;
};

define('DB_NAME', $env('WORDPRESS_DB_NAME', 'wordpress'));
define('DB_USER', $env('WORDPRESS_DB_USER', 'wordpress'));
define('DB_PASSWORD', $env('WORDPRESS_DB_PASSWORD'));
define('DB_HOST', $env('WORDPRESS_DB_HOST', 'infra_mysql_8_0'));
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

// Must match the imported database (make db-pull): empty means the WordPress default.
$table_prefix = $env('WORDPRESS_TABLE_PREFIX', 'wp_');

// Local-only keys: not secrets, they only sign the cookies of this local copy.
define('AUTH_KEY', 'local-auth-key');
define('SECURE_AUTH_KEY', 'local-secure-auth-key');
define('LOGGED_IN_KEY', 'local-logged-in-key');
define('NONCE_KEY', 'local-nonce-key');
define('AUTH_SALT', 'local-auth-salt');
define('SECURE_AUTH_SALT', 'local-secure-auth-salt');
define('LOGGED_IN_SALT', 'local-logged-in-salt');
define('NONCE_SALT', 'local-nonce-salt');

$local_domain = $env('COMPOSE_PROJECT_DOMAIN', 'site.docker.test');
define('WP_HOME', 'https://' . $local_domain);
define('WP_SITEURL', 'https://' . $local_domain);
define('WP_ENVIRONMENT_TYPE', 'local');

// TLS is terminated by Traefik; nginx already forwards HTTPS=on, this covers direct calls.
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && 'https' === $_SERVER['HTTP_X_FORWARDED_PROTO']) {
	$_SERVER['HTTPS'] = 'on';
}

define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);          // wp-content/debug.log (ignored by git)
define('WP_DEBUG_DISPLAY', false);
define('WP_CACHE', false);             // no page-cache drop-in locally
define('AUTOMATIC_UPDATER_DISABLED', true);

// WORDPRESS_DISABLE_CRON=1: no WP-Cron on page loads (run `make wp A="cron event run --due-now"`).
if ('1' === $env('WORDPRESS_DISABLE_CRON', '0')) {
	define('DISABLE_WP_CRON', true);
}

// Mail: PHP mail() goes to the socle's Mailpit (.docker/php/91-local-mail.ini), nothing leaves.

if (!defined('ABSPATH')) {
	define('ABSPATH', __DIR__ . '/');
}

require_once ABSPATH . 'wp-settings.php';
