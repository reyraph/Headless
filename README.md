# WordPress headless pour React

Un WordPress prêt à l'emploi dans un seul conteneur Docker, pour développer un front React qui consomme ses API. L'image contient tout : Apache, PHP, MySQL, WordPress et les extensions du cours.

## Démarrer

Prérequis : [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows, macOS Intel ou Apple Silicon, Linux).

```bash
git clone https://github.com/reyraph/Headless.git
cd Headless
docker compose up -d
```

Le premier démarrage télécharge l'image, puis installe le site en moins d'une minute. Pour savoir où il en est : `docker compose logs -f`. Le site est prêt quand la ligne `[headless] Prêt` apparaît.

| | |
|---|---|
| Site | <http://localhost:8080> |
| Administration | <http://localhost:8080/wp-admin/> |
| Identifiant | `admin` |
| Mot de passe | `headless-dev` |

Ce mot de passe est public : le site n'est accessible que depuis votre machine, et il doit le rester. Pour changer le port ou les identifiants, copiez `.env.example` en `.env` **avant le premier démarrage**.

## Ce que contient l'image

| Composant | Version | Rôle |
|---|---|---|
| PHP | 8.5 | |
| Apache | 2.4 | |
| MySQL | 26.10 | Accessible uniquement depuis le conteneur |
| WordPress | 7.1.3 | |
| Twenty Twenty-One | 2.9 | Thème avec emplacements de menus (`primary`, `footer`) |
| WPGraphQL | 2.26.2 | API GraphQL |
| WP-REST-API V2 Menus | 0.12.1 | Menus dans l'API REST |
| JWT Authentication for WP REST API | 1.5.0 | Authentification par jeton |
| All-in-One WP Migration | 7.113 | Export et import de sites |

Le site démarre avec deux pages, un article et un menu « Menu principal » placé dans l'emplacement `primary`, pour que vos premiers appels renvoient quelque chose.

## Les API

| Besoin | Requête |
|---|---|
| Articles | `GET /wp-json/wp/v2/posts` |
| Pages | `GET /wp-json/wp/v2/pages` |
| Tous les menus | `GET /wp-json/menus/v1/menus` |
| Un menu | `GET /wp-json/menus/v1/menus/menu-principal` |
| Emplacements de menus | `GET /wp-json/menus/v1/locations` |
| Le menu d'un emplacement | `GET /wp-json/menus/v1/locations/primary` |
| GraphQL | `POST /graphql` (explorateur : **GraphQL › GraphiQL IDE** dans l'administration) |
| Obtenir un jeton JWT | `POST /wp-json/jwt-auth/v1/token` |

Les menus se gèrent dans **Apparence › Menus**.

## Brancher React

Le CORS est déjà ouvert : une application Vite sur `http://localhost:5173` peut appeler WordPress directement.

```bash
npm create vite@latest frontend -- --template react
cd frontend
npm install
npm run dev
```

Première requête à essayer, par exemple dans un `useEffect` :

```js
const res = await fetch("http://localhost:8080/wp-json/wp/v2/posts");
const posts = await res.json();
```

## S'authentifier avec JWT

Demandez un jeton avec vos identifiants, puis envoyez-le dans l'en-tête `Authorization` :

```bash
curl -X POST http://localhost:8080/wp-json/jwt-auth/v1/token \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"headless-dev"}'

curl http://localhost:8080/wp-json/wp/v2/users/me \
  -H "Authorization: Bearer VOTRE_JETON"
```

Le même en-tête fonctionne sur `/graphql`.

## Commandes utiles

```bash
docker compose stop                                   # Arrêter en gardant les données
docker compose start                                  # Relancer
docker compose logs -f                                # Suivre les journaux
docker compose exec -u www-data headless wp plugin list   # WP-CLI
docker compose exec headless mysql wordpress          # Console MySQL
docker compose down -v                                # Tout effacer et repartir de zéro
```

**`down -v` efface définitivement votre contenu.** Exportez d'abord avec All-in-One WP Migration si vous voulez le garder.

Vos données sont dans deux volumes Docker (`db` et `wp-content`) : elles survivent aux arrêts et aux mises à jour de l'image. Une nouvelle image ne remplace donc pas les extensions déjà installées dans `wp-content` ; il faut pour cela repartir de zéro avec `down -v`.

## Sauvegarder et restaurer

Dans l'administration, **All-in-One WP Migration › Export** produit un fichier `.wpress`, que **Import** restaure, jusqu'à 512 Mo. Après un import, les identifiants sont ceux du site importé.

## Dépannage

| Symptôme | Cause et solution |
|---|---|
| `port is already allocated` | Le port 8080 est pris : mettez `WP_PORT=8081` dans `.env`, et adaptez les URL de vos appels |
| Le site ne répond pas juste après le démarrage | L'installation est en cours : vérifiez `docker compose logs -f` |
| Un changement du `.env` n'a aucun effet sur les identifiants | Ils ne sont lus qu'à la première installation : `docker compose down -v` puis `up -d` |
| Une requête renvoie du HTML au lieu de JSON | Vérifiez le chemin : les routes REST commencent par `/wp-json/` |

## Limites à connaître

Cet environnement sert à apprendre sur votre machine, **pas à héberger un site en ligne**.

- **WordPress 7.1.3 n'est plus la dernière version** : wordpress.org le signale comme non sûr, la 7.1.4 corrigeant des failles. Le cours fixe cette version et les mises à jour automatiques sont désactivées.
- Le compte root de MySQL n'a pas de mot de passe, le mot de passe administrateur est public et le site est en HTTP.
- WP-REST-API V2 Menus n'a plus été mis à jour depuis 2022 (testé par son auteur jusqu'à WordPress 6.0). Il fonctionne ici, et les tests de l'image le vérifient à chaque construction.

## Pour l'enseignant

Les versions sont fixées par les `ARG` du [Dockerfile](Dockerfile), par exemple pour passer à WordPress 7.1.4 (avec sa somme SHA-1). Chaque modification poussée sur `main` déclenche [le workflow](.github/workflows/docker-publish.yml) : construction sur amd64 et arm64, exécution de [tests/smoke-test.sh](tests/smoke-test.sh) sur chacune, puis publication sur `ghcr.io/reyraph/headless`.

Pour construire et tester localement :

```bash
docker compose up -d --build
bash tests/smoke-test.sh headless-wordpress http://localhost:8080 admin headless-dev
```

Pour le tutorat par IA, [AGENTS.md](AGENTS.md) contient les consignes partagées par les assistants, sur le modèle du support de cours *AI as a coding tutor*.
