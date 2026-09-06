# Backup — Test de restauration & alerting (NOW-25)

Outils pour **prouver que les sauvegardes sont restaurables** et alerter en cas
de problème. Tout est en **lecture seule sur la prod** : on dump (`--single-transaction`)
et on restaure sur un conteneur MySQL **jetable**, jamais sur la prod.

## Contenu

| Fichier | Rôle |
|---|---|
| `restore-test.sh` | Restaure un dossier de dumps `*.sql.gz` sur un conteneur MySQL jetable, lance `CHECK TABLE` sur toutes les tables, mesure le RTO, écrit un rapport JSON. |
| `weekly-restore-check.sh` | Orchestration hebdo : dump read-only prod → `restore-test.sh` → contrôle de taille anormale → **alerte** (e-mail/webhook) sur échec. |
| `backup.env.example` | Référence complète des variables (config par hôte : bases, seuils, alerting). |
| `backup.env.<hôte>.example` | Modèles prêts à l'emploi par hôte prod (`nowis`, `bifacto`) → copier en `backup.env.<hôte>`. |
| `systemd/now-restore-check@.{service,timer}` | Déclencheur hebdomadaire **templaté par hôte** (le serveur n'a pas de `cron`). |

## Usage manuel

```bash
# Test ponctuel d'un dossier de dumps déjà présents
./restore-test.sh --backup-dir /chemin/vers/dumps

# Contrôle hebdo complet d'un hôte (dump prod read-only + restore + alerte)
cp backup.env.nowis.example backup.env.nowis   # puis éditer (clé Brevo)
set -a; . ./backup.env.nowis; set +a
./weekly-restore-check.sh
```

`restore-test.sh` sort en code ≠ 0 si une table est corrompue ou si une
assertion de comptage (`--expect db.table<TAB>n`) échoue.

## Installation du check hebdomadaire (multi-hôtes)

Le serveur n'a **pas** `cron` mais a `systemd` : on utilise un timer utilisateur.
L'unité est **templatée** — une instance par hôte prod (`nowis`, `bifacto`, …),
chacune avec sa config `backup.env.<hôte>`.

```bash
# Sur le serveur, dans ~/Project/Infra (adapter le chemin si besoin)
# 1) Une config par hôte (gitignorée) — renseigner la clé Brevo dans chacune
cp backup/backup.env.nowis.example   backup/backup.env.nowis
cp backup/backup.env.bifacto.example backup/backup.env.bifacto
$EDITOR backup/backup.env.nowis backup/backup.env.bifacto

# 2) Poser l'unité templatée
mkdir -p ~/.config/systemd/user
cp backup/systemd/now-restore-check@.{service,timer} ~/.config/systemd/user/
loginctl enable-linger webadmin
systemctl --user daemon-reload

# 3) Une instance par hôte
systemctl --user enable --now now-restore-check@nowis.timer
systemctl --user enable --now now-restore-check@bifacto.timer
systemctl --user list-timers            # prochains runs lundi ~04:30

# Test immédiat d'un hôte :
systemctl --user start now-restore-check@bifacto.service
journalctl --user -u now-restore-check@bifacto.service -n 50
```

> ⚠️ Ne PAS créer de fichier `backup/backup.env` (sans suffixe d'hôte) : il
> serait sourcé par le script et écraserait la config d'instance passée par
> systemd. La config vit uniquement dans `backup.env.<hôte>`.

## Alerting

- **E-mail** : SMTP brut (aucune dépendance). En local, pointer sur mailpit
  (`localhost:1025`) ; en prod, un MTA ou un relai SMTP authentifié.
- **Webhook** : POST JSON `{"text": "..."}` (compatible Slack/Discord/générique).

**Alerte bloquante** (sujet « ÉCHEC », `exit 1`) si : dump en échec/vide,
restauration ou `CHECK TABLE` en échec, ou **dump rétréci de plus de
`SIZE_SHRINK_PCT`%** sous la médiane — un dump qui maigrit signale une perte de
données ou une troncature.

**Avertissement non bloquant** (sujet « Avertissement volumétrie », `exit 0`) si
le dump **grossit de plus de `SIZE_GROWTH_PCT`%** au-dessus de la médiane. La
croissance est le régime normal d'une base en production : la signaler sans
crier à l'échec évite d'user la vigilance sur l'alerte qui compte.

La médiane porte sur les `HISTORY_WINDOW` derniers **jours** de
`.restore-history.csv`, à raison d'**un point par jour** (le dernier). Sans cette
double précaution, plusieurs runs de calibration le même jour figent la médiane
sur la valeur du premier jour et toute base en croissance alerte indéfiniment.

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
