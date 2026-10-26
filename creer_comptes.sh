#!/usr/bin/env bash
# =============================================================================
# creer_comptes.sh - Exigences C1 et C2 (contexte A : agence web Pixelia)
#
#   C1 : crée les groupes et les comptes décrits dans comptes.csv
#        et installe les clés publiques des comptes du groupe acces_ssh.
#   C2 : crée les répertoires de /srv avec permissions + ACL + ACL par défaut.
#
# Usage   : sudo bash creer_comptes.sh [chemin/vers/comptes.csv]
# Sortie  : 0 = succès, 1 = mauvais usage / pas root, 2 = CSV invalide
#
# Le script est IDEMPOTENT : le relancer ne crée aucun doublon et ne provoque
# aucune erreur (on teste l'existence avant de créer, on "impose" l'état voulu).
# =============================================================================

set -euo pipefail

# --- Paramètres ---------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV="${1:-$REPO_DIR/comptes.csv}"
CLES_DIR="$REPO_DIR/config/cles"
ENTETE_ATTENDUE="login;nom;groupe_principal;groupes_secondaires"

# Date d'expiration des freelances = fin du semestre (justifiée dans DOSSIER.md)
DATE_EXPIRATION_FREELANCE="2027-01-31"

# Groupes qui doivent exister même si personne ne les cite dans le CSV
GROUPES_OBLIGATOIRES=(admins support acces_ssh dev design commercial freelance)

# Droits utilisés dans les ACL : sur un RÉPERTOIRE,
#   lecture  = r-x  (lister le contenu + y entrer)
#   écriture = rwx  (lecture + créer/supprimer des fichiers)
LECT="r-x"
ECRI="rwx"

# --- Fonctions utilitaires ------------------------------------------------------
log() { echo "[creer_comptes] $*"; }
err() { echo "[creer_comptes] ERREUR : $*" >&2; }

usage() {
    echo "Usage : sudo bash $0 [chemin/vers/comptes.csv]" >&2
    exit 1
}

verifier_prerequis() {
    if [[ $EUID -ne 0 ]]; then
        err "ce script doit être lancé en root"
        exit 1
    fi
    if [[ ! -r $CSV ]]; then
        err "fichier CSV introuvable ou illisible : $CSV"
        exit 1
    fi
    if ! command -v setfacl >/dev/null; then
        err "setfacl absent : installer le paquet 'acl' (installer.sh le fait)"
        exit 1
    fi
}

# Lit le CSV sans l'en-tête, en supprimant les \r (fichier édité sous Windows)
# et les lignes vides.
lignes_csv() {
    tail -n +2 "$CSV" | tr -d '\r' | grep -v '^[[:space:]]*$' || true
}

# Vérifie le format du CSV AVANT de toucher au système.
valider_csv() {
    local entete ligne nb_sep login nom gp
    local -i num=1 erreurs=0

    entete="$(head -n 1 "$CSV" | tr -d '\r')"
    if [[ $entete != "$ENTETE_ATTENDUE" ]]; then
        err "en-tête invalide : '$entete' (attendu : '$ENTETE_ATTENDUE')"
        exit 2
    fi

    while IFS= read -r ligne; do
        num+=1
        nb_sep="$(tr -cd ';' <<<"$ligne" | wc -c)"
        if [[ $nb_sep -ne 3 ]]; then
            err "ligne $num : 4 champs attendus séparés par ';' -> '$ligne'"
            erreurs+=1
            continue
        fi
        IFS=';' read -r login nom gp _ <<<"$ligne"
        if [[ ! $login =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            err "ligne $num : login invalide '$login'"
            erreurs+=1
        fi
        if [[ -z $nom || -z $gp ]]; then
            err "ligne $num : nom et groupe_principal sont obligatoires"
            erreurs+=1
        fi
    done < <(lignes_csv)

    if [[ $erreurs -gt 0 ]]; then
        err "$erreurs erreur(s) dans $CSV : aucune modification effectuée"
        exit 2
    fi
}

# Crée un groupe seulement s'il n'existe pas (idempotence).
creer_groupe() {
    local groupe=$1
    if getent group "$groupe" >/dev/null; then
        log "groupe $groupe : déjà présent"
    else
        groupadd "$groupe"
        log "groupe $groupe : créé"
    fi
}

# Crée tous les groupes : obligatoires + tous ceux cités dans le CSV.
creer_groupes() {
    local gp gs g
    local -a tous=("${GROUPES_OBLIGATOIRES[@]}")

    while IFS=';' read -r _ _ gp gs; do
        tous+=("$gp")
        if [[ -n $gs ]]; then
            IFS=',' read -r -a secondaires <<<"$gs"
            tous+=("${secondaires[@]}")
        fi
    done < <(lignes_csv)

    # sort -u supprime les doublons
    for g in $(printf '%s\n' "${tous[@]}" | sort -u); do
        creer_groupe "$g"
    done
}

# Vrai si le groupe $1 apparaît dans "groupe_principal,groupes_secondaires" ($2)
est_membre() {
    [[ ",$2," == *",$1,"* ]]
}

# Installe la clé publique config/cles/<login>.pub dans ~/.ssh/authorized_keys
installer_cle() {
    local login=$1 gp=$2 home=$3
    local source="$CLES_DIR/$login.pub"

    if [[ ! -f $source ]]; then
        log "ATTENTION : pas de clé $source -> $login ne pourra pas se connecter en SSH"
        return 0
    fi
    install -d -m 0700 -o "$login" -g "$gp" "$home/.ssh"
    # tr -d '\r' : protège contre une clé enregistrée avec des fins de ligne Windows
    tr -d '\r' <"$source" >"$home/.ssh/authorized_keys"
    chown "$login:$gp" "$home/.ssh/authorized_keys"
    chmod 0600 "$home/.ssh/authorized_keys"
    log "compte $login : clé publique installée"
}

# Crée ou met à jour un compte pour qu'il corresponde exactement au CSV.
traiter_compte() {
    local login=$1 nom=$2 gp=$3 gs=$4
    local home
    local -a options

    if id -u "$login" >/dev/null 2>&1; then
        # Le compte existe : on impose groupe principal, secondaires et nom.
        # usermod -G remplace la liste des groupes secondaires (vide = aucun).
        usermod -g "$gp" -G "$gs" -c "$nom" "$login"
        log "compte $login : déjà présent, groupes mis à jour"
    else
        options=(-m -s /bin/bash -g "$gp" -c "$nom")
        if [[ -n $gs ]]; then
            options+=(-G "$gs")
        fi
        useradd "${options[@]}" "$login"
        log "compte $login : créé"
    fi
    # Aucun mot de passe n'est défini ici : le compte reste verrouillé par mot
    # de passe (connexion SSH par clé uniquement, cf. S1).

    # C4 : répertoire personnel lisible uniquement par son propriétaire
    home="$(getent passwd "$login" | cut -d: -f6)"
    chmod 0700 "$home"

    # Particularité du contexte A : les freelances expirent en fin de semestre
    if est_membre freelance "$gp,$gs"; then
        chage -E "$DATE_EXPIRATION_FREELANCE" "$login"
        log "compte $login : expire le $DATE_EXPIRATION_FREELANCE"
    else
        chage -E -1 "$login"   # -1 = pas d'expiration (cas d'un changement de groupe)
    fi

    # Clé SSH uniquement pour les comptes autorisés à se connecter
    if est_membre acces_ssh "$gp,$gs"; then
        installer_cle "$login" "$gp" "$home"
    fi
}

creer_comptes() {
    local login nom gp gs
    while IFS=';' read -r login nom gp gs; do
        traiter_compte "$login" "$nom" "$gp" "$gs"
    done < <(lignes_csv)
}

# creer_repertoire CHEMIN ACL_ACCES ACL_DEFAUT
#   ACL_ACCES  : droits sur le répertoire lui-même (ex. "g:dev:rwx,g:design:r-x")
#   ACL_DEFAUT : droits hérités par tout ce qui sera créé dedans plus tard
# Le répertoire appartient à root:root ; ni le groupe propriétaire ni "les
# autres" n'ont de droit : tout passe par les entrées nommées de l'ACL.
creer_repertoire() {
    local chemin=$1 acces=$2 defaut=$3
    local base="u::rwx,g::---,o::---,m::rwx"
    local base_defaut="d:u::rwx,d:g::---,d:o::---,d:m::rwx"
    local defaut_prefixe

    # "g:dev:rwx,g:design:r-x" -> "d:g:dev:rwx,d:g:design:r-x"
    defaut_prefixe="$(sed 's/\(^\|,\)/\1d:/g' <<<"$defaut")"

    install -d -m 0770 -o root -g root "$chemin"
    # --set REMPLACE toute l'ACL : relancer donne exactement le même résultat
    setfacl --set "$base,$acces,$base_defaut,$defaut_prefixe" "$chemin"
    log "répertoire $chemin : droits et ACL appliqués"
}

# Tableau du contexte A traduit en ACL.
creer_repertoires() {
    # /srv/projets : dev rw, design r, commercial -, freelance -
    # freelance reçoit SEULEMENT --x (traverser sans lister ni lire) : sinon
    # il ne pourrait pas atteindre /srv/projets/externe. Ce --x n'est pas mis
    # dans l'ACL par défaut : les futurs sous-dossiers ne lui seront pas ouverts.
    creer_repertoire /srv/projets \
        "g:dev:$ECRI,g:design:$LECT,g:freelance:--x" \
        "g:dev:$ECRI,g:design:$LECT"

    # /srv/projets/externe : dev rw, design r, commercial -, freelance rw
    creer_repertoire /srv/projets/externe \
        "g:dev:$ECRI,g:design:$LECT,g:freelance:$ECRI" \
        "g:dev:$ECRI,g:design:$LECT,g:freelance:$ECRI"

    # /srv/maquettes : dev r, design rw, commercial r, freelance -
    creer_repertoire /srv/maquettes \
        "g:dev:$LECT,g:design:$ECRI,g:commercial:$LECT" \
        "g:dev:$LECT,g:design:$ECRI,g:commercial:$LECT"

    # /srv/clients : dev -, design -, commercial rw, freelance -
    creer_repertoire /srv/clients \
        "g:commercial:$ECRI" \
        "g:commercial:$ECRI"
}

# --- Programme principal ---------------------------------------------------------
main() {
    if [[ $# -gt 1 ]]; then
        usage
    fi
    verifier_prerequis
    valider_csv
    creer_groupes
    creer_comptes
    creer_repertoires
    log "terminé"
}

main "$@"
