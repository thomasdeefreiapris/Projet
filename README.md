# Projet XTI302-CYB - Durcir un serveur Linux et le prouver

**Contexte choisi : A - Agence web Pixelia**

Groupes métier : `dev`, `design`, `commercial`, `freelance`.
Particularité : les comptes `freelance` expirent en fin de semestre et n'ont pas sudo.

## Prérequis

- VM Debian 13 minimale (sans interface graphique, avec serveur SSH), revenue au snapshot « vierge ».
- Second disque virtuel de 2 Go (pour les sauvegardes, séance 5).
- Carte réseau 2 en « réseau privé hôte », IP fixe `192.168.56.10`.
- Une clé publique par compte du groupe `acces_ssh` dans `config/cles/<login>.pub`.

## Installation (depuis le snapshot vierge)

Depuis Windows (PowerShell), copier le dépôt sur la VM :

```powershell
scp -r .\projet-durcissement install@192.168.56.10:/tmp/
```

Puis sur la VM :

```bash
su -                                   # passer root
cp -r /tmp/projet-durcissement /opt/   # le dépôt vit dans /opt
bash /opt/projet-durcissement/installer.sh
```

`installer.sh` demande le mot de passe de chaque administrateur (sudo et console de secours).
Il refuse d'appliquer la config SSH si aucun administrateur n'a de clé, et de verrouiller root
si aucun administrateur n'a de mot de passe.

## Vérification

```bash
sudo bash /opt/projet-durcissement/verifier.sh       # tous les tests
sudo bash /opt/projet-durcissement/verifier.sh S     # seulement les tests S*
```

Code de sortie : `0` si tout est conforme, `1` sinon.

## Contenu

| Fichier | Rôle |
|---|---|
| `comptes.csv` | comptes et groupes |
| `creer_comptes.sh` | C1, C2 : comptes, groupes, clés, `/srv` et ACL |
| `installer.sh` | reconstruit toute la configuration |
| `verifier.sh` | teste chaque exigence |
| `analyse_logs.sh` | J4 : rapport SSH (séance 4) |
| `sauvegarde.sh` | B1 : sauvegarde (séance 5) |
| `config/` | fichiers de configuration et clés publiques |
| `DOSSIER.md` | conformité, choix techniques, défense, restauration |
