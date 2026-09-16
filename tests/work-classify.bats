load work-helpers

setup() {
  setup_work
  G="$WORK_ROOT/bin/work-guard"
}

# writes <commande> [cible attendue, défaut /r] : la commande écrit, depuis le cwd /r
writes() {
  local out
  out="$("$G" --classify "$1" --cwd /r)" || { echo "échec du classifieur : $1"; return 1; }
  echo "$out" | jq -e --arg t "${2:-/r}" '.targets | index($t) != null' >/dev/null \
    || { echo "écriture attendue (${2:-/r}) : $1 → $out"; return 1; }
}

# reads <commande> : aucune cible d'écriture
reads() {
  local out
  out="$("$G" --classify "$1" --cwd /r)" || { echo "échec du classifieur : $1"; return 1; }
  echo "$out" | jq -e '.targets == []' >/dev/null \
    || { echo "lecture attendue : $1 → $out"; return 1; }
}

@test "git : sous-commandes d'écriture" {
  writes "git commit -m 'x'"
  writes "git checkout -b feature/x"
  writes "git switch main"
  writes "git branch feature/x"
  writes "git branch -D feature/x"
  writes "git stash"
  writes "git stash pop"
  writes "git -C /other/repo reset --hard" /other/repo
  writes "git pull"
  writes "git push origin x"
  writes "git merge develop"
  writes "git rebase main"
  writes "git restore f"
  writes "git tag v1"
  writes "git -c core.x=y commit -m m"
}

@test "git : lectures" {
  reads "git status"
  reads "git log --oneline"
  reads "git diff HEAD"
  reads "git fetch origin"
  reads "git branch"
  reads "git branch -a"
  reads "git branch --show-current"
  reads "git stash list"
  reads "git show HEAD"
  reads "git tag -l"
  reads "git rev-parse HEAD"
  reads "git -C /x status"
}

@test "fichiers et redirections" {
  writes "rm -rf var/cache"
  writes "sed -i 's/a/b/' f"
  writes "sed -Ei 's/a/b/' f"
  writes "perl -pi -e 's/a/b/' f"
  writes "touch x"
  writes "mkdir -p a/b"
  writes "cp a b"
  writes "echo x > f" /r/f
  writes "cat a | tee b"
  writes "chmod +x bin/x"
  writes "echo x > /elsewhere/f" /elsewhere/f

  reads "cat f"
  reads "grep -rn x ."
  reads "ls -la"
  reads "sed -n 1,5p f"
  reads "echo x > /tmp/f"
  reads "cmd 2>/dev/null"
  reads "cmd > /dev/null 2>&1"
  reads "find . -name x"
  reads "head -5 f | wc -l"
}

@test "dépendances, make, Symfony, tests" {
  writes "composer require foo/bar"
  writes "composer install"
  writes "npm ci"
  writes "npm install x"
  writes "yarn add x"
  writes "npm run build"
  writes "make test"
  writes "make"
  writes "php bin/console doctrine:migrations:migrate -n"
  writes "bin/console cache:clear"
  writes "php bin/console make:entity"
  writes "vendor/bin/phpunit --filter X"
  writes "bin/phpunit"
  writes "vendor/bin/pest"

  reads "composer show"
  reads "npm ls"
  reads "npm run lint"
  reads "php bin/console debug:router"
}

@test "docker compose" {
  writes "docker compose up -d"
  writes "docker compose -f .docker/docker-compose.yml down"
  writes "docker compose exec php bin/console cache:clear"
  writes "docker compose exec -u www-data php composer install"
  writes "docker-compose run --rm php vendor/bin/phpunit"

  reads "docker compose ps"
  reads "docker compose logs -f php"
  reads "docker compose exec php bin/console debug:router"
  reads "docker logs x"
  reads "docker ps"
}

@test "composition : opérateurs, substitutions, bash -c, cd, préfixes" {
  writes "git status && git commit -m x"
  writes "ls; rm f"
  writes 'echo $(git commit -m x)'
  writes 'echo "$(git commit -m x)"'
  writes "bash -c 'git commit -m x'"
  writes 'sh -c "rm f"'
  writes "cd /other && git commit -m x" /other
  writes "cd sub && make" /r/sub
  writes "FOO=1 make test"
  writes "sudo rm f"
  writes "(cd /other && rm x)" /other

  reads "cd /other && git status"
  reads "git log | head"
  reads "echo 'git commit'"
  reads "grep 'rm -rf' f"
}

@test "work lui-même est toujours autorisé" {
  reads "work start GEL-1"
  reads "/home/webadmin/Project/Infra/bin/work pr --title t"
  reads "bin/work park"
}

@test "les chemins absolus d'un segment d'écriture sont des cibles" {
  run "$G" --classify "rm /x/a /y/b" --cwd /r
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.targets | index("/r")) != null and (.targets | index("/x/a")) != null and (.targets | index("/y/b")) != null' >/dev/null

  run "$G" --classify "cp src/a /dest/b" --cwd /r
  echo "$output" | jq -e '(.targets | index("/dest/b")) != null' >/dev/null
}
