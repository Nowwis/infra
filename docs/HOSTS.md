# Gabarit de fiche par hôte

L'inventaire réel (noms, adresses, bases, destinataires) **n'est pas dans ce dépôt** : il
contient des noms de projets et de machines. Il vit dans un dépôt privé ou un gestionnaire de
secrets, une fiche par hôte selon ce gabarit. La fiche est ce qui rend `RUNBOOK-backup-restore.md`
§4 exécutable le jour où il faut tout remonter.

---

## `<nom-court>` — `<rôle : labo | serveur>`

| | |
|---|---|
| Alias ssh | `<alias ~/.ssh/config>` |
| Système | `<distribution, version>` ; Docker `<version>` |
| Clone du socle | `~/infra`, branche `main`, dernier déploiement `<date>` |
| `ENV` | `local` / `prod` |
| Écoute (`TRAEFIK_BIND`) | `<vide | 127.0.0.1: | ip-privée:>` |
| Devant Traefik | `<rien | CDN | VPN>` |
| Domaines du socle | `<monitoring.…>`, `<pma.…>`, `<mail.…>` |
| Profils Compose | `<aucun | mariadb>` |
| Cron | `0 */6 * * *` rotation des journaux ; `<autres>` |
| Timers systemd (utilisateur) | `<restore-check@…>`, `<autres>` |
| Pare-feu | `<22, 80, 443 ; autres ports et pourquoi>` |

### Applications hébergées

| Projet | Domaine(s) | Stack prod / recette | Base(s) | Dépôt | Déploiement |
|---|---|---|---|---|---|
| `<slug>` | `<domaine>` | prod | `prod_<slug>` | `<url>` | `<manuel | runner | …>` |
| `<slug>` | `dev.<domaine>` | recette | `dev_<slug>` | idem | |

### Bases présentes et couverture

| Base | Moteur | Taille | Sauvegardée par | Contrôlée par `restore-check` |
|---|---|---|---|---|
| `prod_<slug>` | MySQL 8.0 | `<Mo>` | `<outil, cadence, destination>` | oui / non |

### Secrets et où ils sont

| Secret | Emplacement |
|---|---|
| `.env` du socle | `<gestionnaire de secrets, entrée …>` |
| `.env` de chaque application | |
| Clés ssh autorisées | |

### Particularités

Tout ce qu'un remplaçant doit savoir et que la configuration ne dit pas : un CDN en mode
strict, un reverse DNS, une IP allow-listée chez un fournisseur, une application d'un tiers
hébergée à titre provisoire, un cron qui n'est pas dans le dépôt.

### Dernière vérification de la fiche

`<date>` par `<qui>`.
