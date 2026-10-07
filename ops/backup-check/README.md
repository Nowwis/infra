# Contrôle hebdomadaire de restauration

Prouve chaque semaine que les bases d'un serveur sont **restaurables** : dump en lecture seule,
restauration sur un conteneur MySQL jetable, `CHECK TABLE` sur toutes les tables, contrôle de
volumétrie, alerte en cas d'échec. Ne touche jamais le serveur contrôlé autrement qu'en lecture.

Ce dossier **teste** des sauvegardes. Il n'en **produit** pas : chiffrement, rotation et copie
hors site relèvent d'un autre outillage (voir `docs/RUNBOOK-backup-restore.md`).

| Fichier | Rôle |
|---|---|
| `weekly-restore-check.sh` | Orchestration : dump ssh → `restore-test.sh` → taille vs médiane → alerte. Exit ≠ 0 sur échec. |
| `restore-test.sh` | Restaure un dossier de `*.sql.gz` sur un MySQL jetable, `CHECK TABLE`, mesure le RTO, écrit un JSON. Utilisable seul. |
| `backup.env.example` | Toutes les variables. Une copie `backup.env.<hote>` par serveur contrôlé. |
| `systemd/restore-check@.{service,timer}` | Unité templatée : une instance par hôte, lundi 04:30, jitter 10 min. |
| `.restore-history.csv` | Historique des tailles (gitignoré). La médiane s'appuie dessus. |

## Où ça tourne

Sur une machine qui a **docker**, un accès **ssh** vers chaque serveur contrôlé, et le dépôt cloné
en `~/infra`. Ce peut être un poste d'exploitation ou le serveur lui-même (alors `PROD_SSH_HOST`
pointe sur `localhost` via ssh, ou le script est adapté).

## Installation

```bash
cd ~/infra/ops/backup-check
cp backup.env.example backup.env.<hote>        # un par serveur ; renseigner PROD_SSH_HOST, BACKUP_DATABASES, alerting
mkdir -p ~/.config/systemd/user
cp systemd/restore-check@.{service,timer} ~/.config/systemd/user/
loginctl enable-linger "$USER"                 # tourne hors session
systemctl --user daemon-reload
systemctl --user enable --now restore-check@<hote>.timer
systemctl --user list-timers 'restore-check@*'
```

## Usage manuel

```bash
# Un hôte, tout de suite
systemctl --user start restore-check@<hote>.service && journalctl --user -u restore-check@<hote> -n 50

# Sans systemd
set -a; . ./backup.env.<hote>; set +a; ./weekly-restore-check.sh [--notify-success]

# Tester un dossier de dumps déjà présent
./restore-test.sh --backup-dir /chemin/vers/dumps [--expect attendus.tsv] [--keep]
```

## Alerting

Bloquant (exit 1, sujet « ÉCHEC ») : dump vide ou en échec, restauration ou `CHECK TABLE` en
échec, dump rétréci de plus de `SIZE_SHRINK_PCT` % sous la médiane. Avertissement (exit 0) :
croissance de plus de `SIZE_GROWTH_PCT` %. Succès : silencieux, sauf `NOTIFY_SUCCESS=1`.

Canaux, cumulables : e-mail via API Brevo (préféré en prod, IPv4 forcé), SMTP brut (Mailpit en
local), webhook JSON, commande locale sur stdin (`ALERT_NOTIFY_CMD`).

## Ce que ça ne détecte pas

Une machine de contrôle éteinte : aucune alerte « le contrôle n'a pas tourné ». Surveiller
`systemctl --user list-timers` ou garder `NOTIFY_SUCCESS=1` sur un canal lu.
