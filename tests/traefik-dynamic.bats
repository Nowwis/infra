#!/usr/bin/env bats
# Config dynamique Traefik versionnée : règles attendues dans CHAQUE ENV, sans démarrer de conteneur.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  D="$ROOT/configuration/traefik2/config/dynamic"
}

# yget <fichier> <expression python sur d> : valeur lue dans le YAML (PyYAML)
yget() {
  python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

@test "chemins cachés : routeur deny-dotfiles présent en local et en prod" {
  for env in local prod; do
    f="$D/$env/deny-dotfiles.yaml"
    [ -f "$f" ] || { echo "absent : $f"; return 1; }
    r="d['http']['routers']['deny-dotfiles']"
    [ "$(yget "$f" "$r['rule']")" = 'PathRegexp(`^/\.`) && !PathPrefix(`/.well-known/`)' ]
    [ "$(yget "$f" "$r['entrypoints']")" = "['websecure']" ]
    [ "$(yget "$f" "$r['service']")" = "noop@internal" ]
    [ "$(yget "$f" "$r['middlewares']")" = "['deny-all']" ]
    [ "$(yget "$f" "$r['tls']")" = "{}" ]
    # Passe devant tout routeur d'application (priorité par défaut = longueur de la règle).
    [ "$(yget "$f" "$r['priority']")" -ge 10000 ]
  done
}

@test "chemins cachés : deny-all n'autorise que la boucle locale, dans chaque ENV" {
  for env in local prod; do
    f="$D/$env/deny-dotfiles.yaml"
    [ "$(yget "$f" "d['http']['middlewares']['deny-all']['ipAllowList']['sourceRange']")" = "['127.0.0.1/32']" ]
  done
}

@test "chemins cachés : même règle en local et en prod" {
  diff "$D/local/deny-dotfiles.yaml" "$D/prod/deny-dotfiles.yaml"
}

@test "chemins cachés : aucun resolver ACME sur le routeur (pas de demande de certificat sans Host)" {
  for env in local prod; do
    run grep -n certResolver "$D/$env/deny-dotfiles.yaml"
    [ "$status" -eq 1 ]
  done
}

@test "noms de routeurs et de middlewares uniques par ENV" {
  for env in local prod; do
    run python3 -I -c '
import sys, yaml, glob, collections
seen = collections.Counter()
for f in glob.glob(sys.argv[1] + "/*.yaml"):
    d = yaml.safe_load(open(f)) or {}
    for kind in ("routers", "middlewares", "services"):
        for name in ((d.get("http") or {}).get(kind) or {}):
            seen[(kind, name)] += 1
dups = [k for k, n in seen.items() if n > 1]
print(dups); sys.exit(1 if dups else 0)' "$D/$env"
    [ "$status" -eq 0 ] || { echo "$env : $output"; return 1; }
  done
}
