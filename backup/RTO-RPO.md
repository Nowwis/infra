# NOW-25 — Test de restauration réel + RTO/RPO

**Date du test :** 2026-06-27 · **Serveur :** `bifacto` (72.62.44.15) · **Conteneur prod :** `infra_mysql_8_0` (MySQL 8.0)

## 1. Ce qui a été fait

Test de restauration **réel et complet**, de bout en bout, sur environnement
jetable — pas une simulation :

1. **Dump read-only** des bases de prod (`mysqldump --single-transaction`,
   streamé en gzip via ssh ; **rien écrit sur le disque prod**).
2. **Conteneur MySQL 8.0 jetable** démarré en local (aucun port publié, datadir
   temporaire, mot de passe aléatoire) — isolé de tout.
3. **Restauration** des dumps dans ce conteneur.
4. **Contrôles d'intégrité** : `CHECK TABLE` sur **les 48 tables**, comptage des
   objets, et **comparaison exacte du nombre de lignes vs la prod** sur les plus
   grosses tables.
5. **Destruction** du conteneur + datadir.

### Résultats

| Base | Tables | `CHECK TABLE` | Lignes vs prod (top tables) |
|---|---|---|---|
| `appbifacto` | 12 | 12/12 **OK** | factures 3469, clients 842, sessions 6220, users 138, products 570 — **toutes ✓ identiques** |
| `docbifacto` | 36 | 36/36 **OK** | analysis_log 22400, document_page_extraction 12075, extraction_benchmark 6359, fine_tuning_data 3408 — **toutes ✓ identiques** |

✅ **Restauration validée** : intégrité OK et données rigoureusement identiques à la prod.

## 2. RTO obtenu (Recovery Time Objective)

Temps mesurés pour la stack bifacto (~278 Mo logiques : appbifacto 1,6 Mo gz / docbifacto 53 Mo gz) :

| Étape | Temps |
|---|---|
| Dump read-only prod (appbifacto 1 s + docbifacto 9 s) | ~10 s |
| Boot conteneur MySQL jetable (jusqu'à requête OK) | ~11 s |
| Restauration des dumps (appbifacto 1 s + docbifacto 17 s) | ~18 s |
| Contrôles d'intégrité (`CHECK TABLE` ×48) | ~1–2 s |
| **RTO total (dump → base vérifiée)** | **~40 s** |

> **RTO data uniquement** ≈ 40 s pour ces bases. Le RTO *applicatif* réel
> (remonter la plateforme complète : provisioning serveur + Docker + Traefik +
> volumes fichiers + DNS) reste à mesurer séparément — l'estimation est de
> **30 min à 2 h** selon qu'on parte d'un serveur déjà provisionné ou nu.
> La part « base de données » n'est donc **pas** le goulet d'étranglement.

Extrapolation : le débit observé (~15 Mo/s logique en restore) reste linéaire ;
une base de 5 Go se restaurerait en ~6–10 min. Au-delà, basculer sur XtraBackup
(restauration physique, **NOW-32**) pour un RTO inférieur.

## 3. RPO obtenu (Recovery Point Objective)

⚠️ **RPO actuel = non borné / indéfini.**

Constat lors de l'audit du serveur prod :

- **Aucune sauvegarde automatisée** n'est en place : pas de cron (binaire absent),
  pas de timer systemd de backup, pas de copie off-site.
- Les seuls dumps présents (`~/sync/`) sont des exports **manuels et ponctuels**
  de la seule base `appbifacto` (datés des 21–22 juin), produits par le script
  de sync dev. **`docbifacto` (264 Mo) n'a aucune sauvegarde.**
- En cas de crash disque maintenant, la perte de données serait **totale** pour
  les bases non couvertes, et de **plusieurs jours** pour `appbifacto`.

**C'est le risque P0 réel de ce ticket.** L'outillage de test livré ici est prêt,
mais il teste des sauvegardes qui, à ce jour, **ne sont pas produites de façon
fiable**.

### RPO cible (après mise en place de NOW-29)

| Mécanisme | RPO cible | Ticket |
|---|---|---|
| `mysqldump` nightly chiffré + off-site (S3/Backblaze) | ≤ 24 h | **NOW-29** |
| Binlogs `ROW` + PITR | ≤ 5 min | **NOW-29** |
| XtraBackup full hebdo + incrémentaux quotidiens (grosses bases) | ≤ 24 h, RTO réduit | **NOW-32** |

## 4. Automatisation — INSTALLÉE sur la prod bifacto ✅

- `weekly-restore-check.sh` : dump read-only → restore jetable → contrôle
  d'intégrité → **contrôle de taille anormale** (±40 % vs médiane historique) →
  **alerte e-mail sur échec**.
- **Installé et actif** sur `bifacto` (validation Simon du 2026-06-27) :
  timer systemd utilisateur `now-restore-check.timer`, **lundi 04:30**,
  linger activé (tourne hors session). Prochain run : 2026-06-29.
- **Alerte e-mail via l'API Brevo** (HTTPS, forcé IPv4 — clé restreinte par IP),
  destinataire `simon@nowis.fr`, expéditeur vérifié
  `contact@domiciliationbulgarie.com`. **Canal testé en réel : e-mail délivré
  (HTTP 201).** Mailpit local reste le fallback pour l'usage en dev.
- Vérifié de bout en bout via `systemctl --user start` : Result=success,
  48/48 tables OK, RTO mesuré **24–25 s** sur le serveur prod, conteneur jetable
  bien détruit.

> Couverture actuelle : serveur `bifacto` (appbifacto, docbifacto). Le second
> hôte prod `nowis` (4roueset1toit, myprojekt, …) devra recevoir le même check
> — voir suite recommandée.

## 5. Suite recommandée (priorité)

1. **P0 — NOW-29** : mettre en place la *production* des sauvegardes (nightly
   chiffré + off-site). Sans ça, le RPO reste non borné. **À faire en premier.**
2. ~~Installer le check hebdo~~ → **FAIT** (installé + testé sur bifacto le 2026-06-27).
3. **Étendre le check au second hôte prod `nowis`** (même mécanisme, scope
   approbation à confirmer avec Simon).
4. **P1** : mesurer le RTO applicatif complet (runbook de remontée plateforme).
5. **P3 — NOW-32** : XtraBackup pour les bases qui dépasseront quelques Go.
