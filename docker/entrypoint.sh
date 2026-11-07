#!/usr/bin/env bash
# Démarre MySQL, installe WordPress au premier lancement, puis démarre Apache.
set -euo pipefail

DATADIR=/var/lib/mysql
WP_PATH=/var/www/html
# Sur le volume de la base : ils survivent à la recréation du conteneur. Le marqueur
# est un fichier, et non une option WordPress, car un import .wpress remplace les tables.
SECRETS="$DATADIR/.headless-secrets"
SEEDED="$DATADIR/.headless-seeded"

export WP_URL="${WP_URL:-http://localhost:8080}"
MYSQL_PID=""
APACHE_PID=""

log() { echo "[headless] $*"; }
wp_raw() { runuser -u www-data -- wp --path="$WP_PATH" "$@"; }
wp_cli() { wp_raw --quiet "$@"; }
random_hex() { php -r "echo bin2hex(random_bytes($1));"; }

shutdown() {
    local code="${1:-0}"
    trap - TERM INT
    log "Arrêt des services…"
    if [ -n "$APACHE_PID" ]; then kill -TERM "$APACHE_PID" 2>/dev/null || true; fi
    if [ -n "$MYSQL_PID" ]; then kill -TERM "$MYSQL_PID" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    exit "$code"
}
trap 'shutdown 0' TERM INT

start_mysql() {
    mkdir -p /run/mysqld
    chown mysql:mysql /run/mysqld "$DATADIR"
    if [ ! -d "$DATADIR/mysql" ]; then
        log "Initialisation de MySQL…"
        mysqld --initialize-insecure --user=mysql
    fi
    mysqld &
    MYSQL_PID=$!
    local tries=120
    until mysqladmin --silent ping >/dev/null 2>&1; do
        if ! kill -0 "$MYSQL_PID" 2>/dev/null; then
            log "ERREUR : MySQL s'est arrêté au démarrage"
            exit 1
        fi
        tries=$((tries - 1))
        if [ "$tries" -le 0 ]; then
            log "ERREUR : MySQL ne répond pas"
            shutdown 1
        fi
        sleep 1
    done
}

load_secrets() {
    if [ ! -f "$SECRETS" ]; then
        (
            umask 077
            {
                echo "DB_PASSWORD=$(random_hex 24)"
                echo "JWT_SECRET=$(random_hex 32)"
                for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
                    echo "$key=$(random_hex 32)"
                done
            } > "$SECRETS"
        )
    fi
    # shellcheck disable=SC1090
    . "$SECRETS"
}

write_wp_config() {
    install -o www-data -g www-data -m 640 /dev/null "$WP_PATH/wp-config.php"
    cat > "$WP_PATH/wp-config.php" <<PHP
<?php
define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'wordpress' );
define( 'DB_PASSWORD', '$DB_PASSWORD' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

define( 'AUTH_KEY', '$AUTH_KEY' );
define( 'SECURE_AUTH_KEY', '$SECURE_AUTH_KEY' );
define( 'LOGGED_IN_KEY', '$LOGGED_IN_KEY' );
define( 'NONCE_KEY', '$NONCE_KEY' );
define( 'AUTH_SALT', '$AUTH_SALT' );
define( 'SECURE_AUTH_SALT', '$SECURE_AUTH_SALT' );
define( 'LOGGED_IN_SALT', '$LOGGED_IN_SALT' );
define( 'NONCE_SALT', '$NONCE_SALT' );

\$table_prefix = 'wp_';

// L'URL suit l'en-tête Host : le site fonctionne quel que soit le port publié.
\$headless_url = isset( \$_SERVER['HTTP_HOST'] ) ? 'http://' . \$_SERVER['HTTP_HOST'] : getenv( 'WP_URL' );
define( 'WP_HOME', \$headless_url );
define( 'WP_SITEURL', \$headless_url );

define( 'JWT_AUTH_SECRET_KEY', '$JWT_SECRET' );
define( 'JWT_AUTH_CORS_ENABLE', true );

define( 'WP_ENVIRONMENT_TYPE', 'local' );
define( 'WP_DEBUG', false );
define( 'DISALLOW_FILE_EDIT', true );
// Le cours fixe la version de WordPress : pas de mise à jour automatique.
define( 'WP_AUTO_UPDATE_CORE', false );

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
PHP
}

create_database() {
    mysql <<SQL
CREATE DATABASE IF NOT EXISTS wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'wordpress'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'localhost';
SQL
}

seed_wordpress() {
    local admin_user="${WP_ADMIN_USER:-admin}"
    local admin_password="${WP_ADMIN_PASSWORD:-}"
    if [ -z "$admin_password" ]; then
        admin_password="$(random_hex 12)"
        log "Mot de passe administrateur généré pour $admin_user : $admin_password"
    fi

    log "Installation de WordPress…"
    wp_cli core install \
        --url="$WP_URL" \
        --title="${WP_SITE_TITLE:-Headless WordPress}" \
        --admin_user="$admin_user" \
        --admin_password="$admin_password" \
        --admin_email="${WP_ADMIN_EMAIL:-admin@example.com}" \
        --skip-email
    wp_cli rewrite structure '/%postname%/'
    wp_cli theme activate twentytwentyone
    wp_cli plugin activate wp-graphql all-in-one-wp-migration jwt-authentication-for-wp-rest-api wp-rest-api-v2-menus
    # Permet aux outils du front (Apollo, codegen) d'explorer le schéma GraphQL
    wp_cli option update graphql_general_settings '{"public_introspection_enabled":"on"}' --format=json

    log "Création du contenu de démonstration…"
    local home_id about_id post_id menu_id
    home_id="$(wp_raw post create --post_type=page --post_status=publish --post_title='Accueil' --post_content="Page d'accueil servie par WordPress." --porcelain)"
    about_id="$(wp_raw post create --post_type=page --post_status=publish --post_title='À propos' --post_content='Page de démonstration pour tester le menu.' --porcelain)"
    post_id="$(wp_raw post create --post_status=publish --post_title='Premier article headless' --post_content='Cet article est lu par React via REST ou GraphQL.' --porcelain)"
    menu_id="$(wp_raw menu create 'Menu principal' --porcelain)"
    wp_cli menu item add-post "$menu_id" "$home_id"
    wp_cli menu item add-post "$menu_id" "$about_id"
    wp_cli menu item add-post "$menu_id" "$post_id"
    wp_cli menu location assign "$menu_id" primary
    wp_cli rewrite flush
}

start_mysql
load_secrets
create_database
write_wp_config
chown -R www-data:www-data "$WP_PATH/wp-content"

if [ ! -f "$SEEDED" ]; then
    # Repart de zéro si un premier démarrage a été interrompu en cours d'installation
    if wp_raw core is-installed 2>/dev/null; then
        mysql -e 'DROP DATABASE wordpress;'
        create_database
    fi
    seed_wordpress
    touch "$SEEDED"
fi

# WP-Cron, Santé du site et All-in-One s'appellent eux-mêmes via l'URL du site :
# Apache doit donc aussi écouter sur le port publié à l'extérieur du conteneur.
if [[ "$WP_URL" =~ :([0-9]+)/?$ ]] && [ "${BASH_REMATCH[1]}" != 80 ]; then
    echo "Listen ${BASH_REMATCH[1]}" > /etc/apache2/conf-enabled/headless-port.conf
fi

apache2-foreground &
APACHE_PID=$!
log "Prêt : $WP_URL (administration : $WP_URL/wp-admin/)"

wait -n "$MYSQL_PID" "$APACHE_PID" || true
log "ERREUR : un service s'est arrêté de façon inattendue"
shutdown 1
