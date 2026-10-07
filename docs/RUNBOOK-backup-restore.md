# Runbook — sauvegarde et restauration

## 1. Ce que le dépôt fournit, et ce qu'il ne fournit pas

| | Fourni ici | À mettre en place par ailleurs |
|---|---|---|
| Prouver qu'une base est restaurable | `ops/backup-check` : dump en lecture seule, restauration sur un conteneur jetable, `CHECK TABLE`, contrôle de volume, alerte | |
| Restaurer à la main | §3 ci-dessous | |
| **Produire** des sauvegardes conservées (chiffrement, rotation, copie hors site) | | Un timer par serveur : dump nightly `--single-transaction` de toutes les bases, chiffrement (`age` ou GPG), rotation (7 quotidiens, 4 hebdomadaires), copie vers un stockage objet ou une machine distincte |
| Point de reprise fin (PITR) | | Journaux binaires `ROW` activés dans `configuration/mysql_8_0/conf.d/`, archivés avec les dumps |

Tant que la colonne de droite n'existe pas, le **RPO n'est pas borné** : le contrôle hebdomadaire
valide des dumps qu'il fabrique et jette. Il donne une assurance sur la *restaurabilité*, pas sur
la *disponibilité* d'une sauvegarde le jour où le disque meurt.

## 2. Contrôle hebdomadaire

Installation et usage : `ops/backup-check/README.md`. Ce qu'il mesure, pour une base de
quelques centaines de Mo : dump ~10 s, démarrage du conteneur jetable ~10 s, restauration
~20 s, vérifications ~2 s. Le débit de restauration observé est de l'ordre de 15 Mo/s
logiques : une base de 5 Go se restaure en 6 à 10 minutes. Au-delà de quelques Go, envisager
une sauvegarde physique (XtraBackup) pour un RTO plus court.

Lecture des alertes :

| Sujet | Sens | Faire |
|---|---|---|
| ÉCHEC — dump vide ou en échec | ssh, conteneur ou droits | Vérifier `ssh <hote> docker exec <conteneur> true` |
| ÉCHEC — restauration ou CHECK TABLE | dump corrompu ou table endommagée **en prod** | `CHECK TABLE` sur la prod, en lecture ; ne rien réparer sans dump préalable |
| ÉCHEC — dump rétréci de plus de N % | perte de données ou troncature | Comparer les comptages de lignes avec le run précédent |
| Avertissement volumétrie | croissance normale | Rien, ou ajuster `SIZE_GROWTH_PCT` |
| Rien du tout un lundi | la machine de contrôle n'a pas tourné | `systemctl --user list-timers 'restore-check@*'` |

## 3. Restauration manuelle d'une base

Depuis un dump `prod_monapp.sql.gz` :

```bash
# 1. Vérifier le dump sur un conteneur jetable AVANT de toucher la prod
~/infra/ops/backup-check/restore-test.sh --backup-dir /chemin/du/dossier --pattern 'prod_monapp.sql.gz'

# 2. Mettre l'application en maintenance (ou l'arrêter) pour figer les écritures
cd ~/monapp && docker compose stop php worker

# 3. Dump de sécurité de l'état actuel, même cassé
docker exec infra_mysql_8_0 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --single-transaction --routines --triggers --events prod_monapp' | gzip > ~/prod_monapp.avant-restauration.$(date +%F-%H%M).sql.gz

# 4. Restaurer dans une base NEUVE, puis permuter : pas de fenêtre sans base
docker exec -i infra_mysql_8_0 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "CREATE DATABASE prod_monapp_restore CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"'
zcat prod_monapp.sql.gz | docker exec -i infra_mysql_8_0 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot prod_monapp_restore'
# comptages sur les tables clés, puis :
~/infra/ops/sync-db-names.sh --apply prod_monapp:prod_monapp_old prod_monapp_restore:prod_monapp   # ou RENAME TABLE table par table

# 5. Redémarrer, vérifier, puis supprimer prod_monapp_old après quelques jours
cd ~/monapp && docker compose start php worker
```

Un dump MySQL se restaure dans MariaDB et inversement pour des schémas simples ; `JSON`,
collations récentes et quelques fonctions ne passent pas. Restaurer sur le **même** moteur.

## 4. Restauration complète d'un hôte

Le RTO « données » est de quelques minutes. Le RTO **applicatif** (serveur nu → tout en ligne)
se compte en heures et dépend de ce qui est documenté : DNS, `.env` de chaque application,
volumes de fichiers des applications, secrets. Ordre :

1. Serveur, Docker, utilisateur, clés ssh, pare-feu (80, 443, 22).
2. `~/infra` : clone, `.env` (depuis le gestionnaire de secrets), `make networks && make up`.
   Let's Encrypt réémet les certificats dès que le DNS pointe.
3. Bases : restaurer chaque dump (§3, étape 4 sans permutation).
4. Applications : clone, `.env`, volumes de fichiers depuis leur sauvegarde, `docker compose up -d`.
5. Cron de rotation, timers.

Tenir à jour l'inventaire privé par hôte (`HOSTS.md` en donne le gabarit) : c'est lui qui rend
cette liste exécutable un mauvais jour.
