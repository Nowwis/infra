# Backup — Test de restauration & alerting (NOW-25)

Outils pour **prouver que les sauvegardes sont restaurables** et alerter en cas
de problème. Tout est en **lecture seule sur la prod** : on dump (`--single-transaction`)
et on restaure sur un conteneur MySQL **jetable**, jamais sur la prod.

## Contenu

| Fichier | Rôle |
|---|---|
| `restore-test.sh` | Restaure un dossier de dumps `*.sql.gz` sur un conteneur MySQL jetable, lance `CHECK TABLE` sur toutes les tables, mesure le RTO, écrit un rapport JSON. |
| `weekly-restore-check.sh` | Orchestration hebdo : dump read-only prod → `restore-test.sh` → contrôle de taille anormale → **alerte** (e-mail/webhook) sur échec. |
| `backup.env.example` | Config (hôte ssh, bases, seuils, alerting). À copier en `backup.env`. |
| `systemd/now-restore-check.{service,timer}` | Déclencheur hebdomadaire (le serveur n'a pas de `cron`). |

## Usage manuel

```bash
# Test ponctuel d'un dossier de dumps déjà présents
./restore-test.sh --backup-dir /chemin/vers/dumps

# Contrôle hebdo complet (dump prod read-only + restore + alerte)
cp backup.env.example backup.env   # puis éditer
./weekly-restore-check.sh
```

`restore-test.sh` sort en code ≠ 0 si une table est corrompue ou si une
assertion de comptage (`--expect db.table<TAB>n`) échoue.

## Installation du check hebdomadaire (à valider par Simon)

Le serveur `bifacto` n'a **pas** `cron` mais a `systemd` : on utilise un timer
utilisateur.

```bash
# Sur le serveur, dans ~/Infra (adapter le chemin)
cp backup/backup.env.example backup/backup.env && nano backup/backup.env
mkdir -p ~/.config/systemd/user
cp backup/systemd/now-restore-check.{service,timer} ~/.config/systemd/user/
loginctl enable-linger webadmin
systemctl --user daemon-reload
systemctl --user enable --now now-restore-check.timer
systemctl --user list-timers          # prochain run lundi 04:30
# Test immédiat :
systemctl --user start now-restore-check.service
journalctl --user -u now-restore-check.service -n 50
```

## Alerting

- **E-mail** : SMTP brut (aucune dépendance). En local, pointer sur mailpit
  (`localhost:1025`) ; en prod, un MTA ou un relai SMTP authentifié.
- **Webhook** : POST JSON `{"text": "..."}` (compatible Slack/Discord/générique).

Alerte déclenchée si : dump en échec/vide, restauration ou `CHECK TABLE` en
échec, ou **taille du dump hors de ±`SIZE_DEVIATION_PCT`%** de la médiane des
exécutions précédentes (`.restore-history.csv`).

## RTO / RPO

Voir le rapport détaillé : `RTO-RPO.md`. Résumé du test réel du 2026-06-27 :

- **RTO mesuré** (stack bifacto, ~278 Mo logiques, appbifacto + docbifacto) :
  dump ~10 s + boot jetable ~11 s + restore ~18 s + checks ≈ **~40 s** au total.
- **RPO actuel** : ⚠️ **non borné** — aucune sauvegarde automatisée n'existe à
  ce jour (seulement des dumps manuels ponctuels d'`appbifacto`). À corriger via
  **NOW-29** (mysqldump nightly chiffré + off-site 3-2-1).

> ⚠️ Ce dossier **teste** des sauvegardes ; il n'en **produit** pas de façon
> pérenne (chiffrement, rotation, off-site). La création des sauvegardes de
> production est couverte par **NOW-29** (et **NOW-32** pour XtraBackup).
