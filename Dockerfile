# Image tout-en-un pour le cours WebDev : WordPress headless pour un front React.
# Apache + PHP + MySQL + WordPress dans un seul conteneur.

ARG PHP_VERSION=8.5
# Valeur du tag "latest" de l'image officielle mysql (branche innovation).
# En changeant de série, adapter aussi le chemin /usr/share/mysql-XX plus bas.
ARG MYSQL_VERSION=26.10.0

# Les binaires viennent de l'image officielle : Oracle ne publie ni paquet Debian
# arm64 ni archive minimale arm64, et les étudiants sur Mac Apple Silicon en ont besoin.
FROM mysql:${MYSQL_VERSION} AS mysql-dist

FROM php:${PHP_VERSION}-apache

ARG WP_VERSION=7.1.3
ARG WP_SHA1=491a78c7676b15dffcc69130c6054b8f49228a91
ARG WP_CLI_VERSION=2.12.0
ARG THEME_TWENTYTWENTYONE=2.9
ARG PLUGIN_WP_GRAPHQL=2.26.2
ARG PLUGIN_AIO_MIGRATION=7.113
ARG PLUGIN_JWT_AUTH=1.5.0
ARG PLUGIN_REST_MENUS=0.12.1

LABEL org.opencontainers.image.title="Headless WordPress" \
      org.opencontainers.image.description="WordPress, PHP, Apache et MySQL pour développer un front React headless" \
      org.opencontainers.image.source="https://github.com/reyraph/Headless" \
      org.opencontainers.image.authors="Raphaël Rey"

# Dépendances d'exécution de MySQL et de WP-CLI
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libaio1t64 libncurses6 libtinfo6 less unzip

# Extensions PHP requises ou recommandées par WordPress (OPcache est intégré depuis PHP 8.5).
# Les paquets -dev sont retirés ensuite, seules les bibliothèques utilisées restent.
RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get install -y --no-install-recommends \
        libfreetype6-dev libicu-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" bcmath exif gd intl mysqli zip; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    extdir="$(php -r 'echo ini_get("extension_dir");')"; \
    ldd "$extdir"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u | xargs -r dpkg-query --search | cut -d: -f1 | sort -u | xargs -r apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*; \
    for ext in bcmath exif gd intl mysqli zip; do php -m | grep -qx "$ext"; done

# MySQL
COPY --from=mysql-dist /usr/sbin/mysqld /usr/sbin/mysqld
COPY --from=mysql-dist /usr/bin/mysql /usr/bin/mysqladmin /usr/bin/mysqldump /usr/bin/
COPY --from=mysql-dist /usr/lib64/mysql/private /usr/lib64/mysql/private
COPY --from=mysql-dist /usr/lib64/mysql/plugin/component_reference_cache.so /usr/lib64/mysql/plugin/
COPY --from=mysql-dist /usr/share/mysql-26.10 /usr/share/mysql-26.10
COPY docker/my.cnf /etc/my.cnf
# Debian trixie nomme la bibliothèque libaio.so.1t64, mysqld attend libaio.so.1
RUN set -eux; \
    libaio="$(find /usr/lib /lib -name 'libaio.so.1t64' | head -n1)"; \
    ln -s "$libaio" "$(dirname "$libaio")/libaio.so.1"; \
    groupadd --system mysql; \
    useradd --system --gid mysql --home-dir /var/lib/mysql --shell /usr/sbin/nologin mysql; \
    mkdir -p /var/lib/mysql /run/mysqld; \
    chown mysql:mysql /var/lib/mysql /run/mysqld; \
    mysqld --version; \
    mysql --version

# Apache et PHP
COPY docker/apache-vhost.conf /etc/apache2/sites-available/000-default.conf
COPY docker/php.ini /usr/local/etc/php/conf.d/zz-headless.ini
RUN a2enmod rewrite headers setenvif

# WP-CLI, vérifié par somme de contrôle
RUN set -eux; \
    base="https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
    curl -fsSL "$base" -o /usr/local/bin/wp; \
    echo "$(curl -fsSL "$base.sha512")  /usr/local/bin/wp" | sha512sum -c -; \
    chmod 755 /usr/local/bin/wp
ENV WP_CLI_CACHE_DIR=/tmp/wp-cli-cache

# WordPress, vérifié par somme de contrôle
RUN set -eux; \
    curl -fsSL "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz" -o /tmp/wp.tar.gz; \
    echo "${WP_SHA1}  /tmp/wp.tar.gz" | sha1sum -c -; \
    tar -xzf /tmp/wp.tar.gz -C /var/www/html --strip-components=1; \
    rm /tmp/wp.tar.gz
COPY docker/htaccess /var/www/html/.htaccess

# Thème classique à emplacements de menus, et extensions épinglées
RUN set -eux; \
    fetch() { \
        curl -fsSL "https://downloads.wordpress.org/$1" -o /tmp/pkg.zip; \
        unzip -q /tmp/pkg.zip -d "/var/www/html/wp-content/$2"; \
        rm /tmp/pkg.zip; \
    }; \
    fetch "theme/twentytwentyone.${THEME_TWENTYTWENTYONE}.zip" themes; \
    fetch "plugin/wp-graphql.${PLUGIN_WP_GRAPHQL}.zip" plugins; \
    fetch "plugin/all-in-one-wp-migration.${PLUGIN_AIO_MIGRATION}.zip" plugins; \
    fetch "plugin/jwt-authentication-for-wp-rest-api.${PLUGIN_JWT_AUTH}.zip" plugins; \
    fetch "plugin/wp-rest-api-v2-menus.${PLUGIN_REST_MENUS}.zip" plugins; \
    chown -R www-data:www-data /var/www/html

COPY docker/entrypoint.sh /usr/local/bin/headless-entrypoint
RUN chmod 755 /usr/local/bin/headless-entrypoint

# La base et wp-content survivent à la recréation du conteneur
VOLUME ["/var/lib/mysql", "/var/www/html/wp-content"]
EXPOSE 80
# L'image php:apache utilise SIGWINCH, que le script de démarrage ne reçoit pas comme un arrêt
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=15s --timeout=5s --start-period=180s --retries=5 \
    CMD curl -fsS -o /dev/null http://127.0.0.1/wp-json/ || exit 1
ENTRYPOINT ["headless-entrypoint"]
