#!/usr/bin/env bash
# Vérifie un conteneur démarré.
# Usage : tests/smoke-test.sh CONTENEUR URL UTILISATEUR MOT_DE_PASSE
set -uo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash ne doit pas réécrire les chemins passés à docker exec

C="$1"
URL="$2"
USER_NAME="$3"
PASSWORD="$4"
ORIGIN="http://localhost:5173"
EXPECTED_WP="${EXPECTED_WP:-7.1.3}"
failures=0

check() { # check DESCRIPTION MOTIF TEXTE
    if printf '%s' "$3" | grep -qE "$2"; then
        echo "ok    $1"
    else
        echo "ECHEC $1"
        echo "      attendu : $2"
        echo "      reçu    : $(printf '%s' "$3" | head -c 400)"
        failures=$((failures + 1))
    fi
}
wpc() { docker exec -u www-data "$C" wp --path=/var/www/html "$@" 2>&1; }
graphql() { curl -s -H 'Content-Type: application/json' "$@" "$URL/graphql"; }
preflight() {
    curl -s -D - -o /dev/null -X OPTIONS -H "Origin: $ORIGIN" \
        -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: authorization,content-type' \
        "$URL$1" | tr -d '\r' | tr 'A-Z' 'a-z'
}

for _ in $(seq 1 120); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null)" = healthy ] && break
    if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != true ]; then
        echo "ECHEC conteneur arrêté"
        docker logs --tail 30 "$C" 2>&1
        exit 1
    fi
    sleep 2
done
check "conteneur sain" '^healthy$' "$(docker inspect -f '{{.State.Health.Status}}' "$C")"

check "PHP 8.5" '^PHP 8\.5\.' "$(docker exec "$C" php -v | head -n1)"
check "Apache 2.4" 'Apache/2\.4' "$(docker exec "$C" apache2 -v | head -n1)"
check "MySQL 26" 'Ver 26\.' "$(docker exec "$C" mysqld --version)"
check "WordPress $EXPECTED_WP" "^${EXPECTED_WP//./\\.}\$" "$(wpc core version)"
check "thème à emplacement primary" 'primary' "$(wpc menu location list --format=csv)"
plugins="$(wpc plugin list --status=active --field=name)"
for p in wp-graphql all-in-one-wp-migration jwt-authentication-for-wp-rest-api wp-rest-api-v2-menus; do
    check "extension active : $p" "$p" "$plugins"
done

check "REST : articles" 'Premier article headless' "$(curl -s "$URL/wp-json/wp/v2/posts")"
check "Menus : liste" 'menu-principal' "$(curl -s "$URL/wp-json/menus/v1/menus")"
check "Menus : emplacements" 'primary' "$(curl -s "$URL/wp-json/menus/v1/locations")"
check "Menus : éléments" 'Accueil' "$(curl -s "$URL/wp-json/menus/v1/locations/primary")"

check "GraphQL : articles" 'Premier article headless' "$(graphql -d '{"query":"{ posts { nodes { title } } }"}')"
check "GraphQL : menu" 'Accueil' "$(graphql -d '{"query":"{ menuItems(where:{location:PRIMARY}) { nodes { label } } }"}')"
check "GraphQL : introspection publique" '"__schema"' "$(graphql -d '{"query":"{ __schema { queryType { name } } }"}')"

login="$(curl -s -H 'Content-Type: application/json' -d "{\"username\":\"$USER_NAME\",\"password\":\"$PASSWORD\"}" "$URL/wp-json/jwt-auth/v1/token")"
check "JWT : jeton obtenu" '"token"' "$login"
token="$(printf '%s' "$login" | sed -E 's/.*"token":"([^"]+)".*/\1/')"
auth="Authorization: Bearer $token"
check "JWT : jeton valide" 'jwt_auth_valid_token' "$(curl -s -X POST -H "$auth" "$URL/wp-json/jwt-auth/v1/token/validate")"
check "JWT : identité via REST" "\"slug\":\"$USER_NAME\"" "$(curl -s -H "$auth" "$URL/wp-json/wp/v2/users/me")"
created="$(curl -s -H "$auth" -H 'Content-Type: application/json' -d '{"title":"Test JWT"}' "$URL/wp-json/wp/v2/posts")"
check "JWT : écriture via REST" '"status":"draft"' "$created"
draft_id="$(printf '%s' "$created" | sed -E 's/^\{"id":([0-9]+).*/\1/')"
curl -s -o /dev/null -X DELETE -H "$auth" "$URL/wp-json/wp/v2/posts/$draft_id?force=true"
check "JWT : GraphQL authentifié" "\"name\":\"$USER_NAME\"" "$(graphql -H "$auth" -d '{"query":"{ viewer { name } }"}')"
check "JWT : mauvais mot de passe refusé" '^403$' "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "{\"username\":\"$USER_NAME\",\"password\":\"faux\"}" "$URL/wp-json/jwt-auth/v1/token")"

for path in /wp-json/wp/v2/posts /wp-json/jwt-auth/v1/token /wp-json/menus/v1/menus /graphql; do
    headers="$(preflight "$path")"
    check "CORS : origine $path" "access-control-allow-origin: ($ORIGIN|\*)" "$headers"
    check "CORS : Authorization $path" 'access-control-allow-headers:.*authorization' "$headers"
done
check "CORS : réponse GET" "access-control-allow-origin: ($ORIGIN|\*)" "$(curl -s -D - -o /dev/null -H "Origin: $ORIGIN" "$URL/wp-json/wp/v2/posts" | tr -d '\r' | tr 'A-Z' 'a-z')"

check "boucle locale sur le port publié" '^200$' "$(docker exec "$C" curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL/wp-json/")"
check "All-in-One : limite d'import 512 Mo" '^512M$' "$(docker exec "$C" php -r 'echo ini_get("upload_max_filesize");')"
check "wp-config.php non servi" '^403$' "$(curl -s -o /dev/null -w '%{http_code}' "$URL/wp-config.php")"
check "MySQL n'écoute que dans le conteneur" 'bind_address.*127\.0\.0\.1' "$(docker exec "$C" mysql -Ne "SHOW VARIABLES LIKE 'bind_address'")"

echo "----"
if [ "$failures" -gt 0 ]; then
    echo "$failures vérification(s) en échec"
    exit 1
fi
echo "Toutes les vérifications ont réussi"
