#!/usr/bin/env bash
# =============================================================================
# verifier.sh - vérifie automatiquement chaque exigence du cahier des charges
#
# Usage  : sudo bash verifier.sh [FILTRE]
#          FILTRE optionnel : préfixe d'exigence (ex. "S" ou "C2")
# Sortie : 0 si tout est conforme, 1 sinon (2 = mauvais usage / pas root)
#
# Le script ne modifie JAMAIS le système : seuls des fichiers de test
# temporaires sont créés dans /srv, et ils sont supprimés à la fin (trap).
#
# Pourquoi pas "set -euo pipefail" ici ?
#   -e        : un test qui échoue arrêterait tout le script. Or le rôle de
#               verifier.sh est justement de lancer des commandes qui échouent.
#   pipefail  : dans "cmd | grep -q motif", grep s'arrête dès qu'il trouve ;
#               cmd reçoit alors SIGPIPE et pipefail ferait échouer un test juste.
#   -u        : gardé, il détecte les fautes de frappe dans les noms de variables.
# =============================================================================

# shellcheck disable=SC2317  # les fonctions test_* sont appelées indirectement
set -u
export LC_ALL=C   # messages de sudo, passwd... en anglais, donc analysables

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV="$REPO_DIR/comptes.csv"
FILTRE="${1:-}"

SSHD_CONF_DST="/etc/ssh/sshd_config.d/10-durcissement.conf"
SSHD_CONF_SRC="$REPO_DIR/config/ssh/sshd_config.d/10-durcissement.conf"
SUDOERS_DST="/etc/sudoers.d/projet"
ANALYSE="/usr/local/sbin/analyse_logs.sh"
GROUPES_METIER=(dev design commercial freelance)

NB_OK=0
NB_TOTAL=0
FICHIERS_TEMP=()

# Couleurs seulement si la sortie est un terminal
if [[ -t 1 ]]; then
    VERT=$'\e[32m'; ROUGE=$'\e[31m'; RAZ=$'\e[0m'
else
    VERT=""; ROUGE=""; RAZ=""
fi

# --- Affichage -------------------------------------------------------------------
ok() {
    NB_OK=$((NB_OK + 1)); NB_TOTAL=$((NB_TOTAL + 1))
    printf '%s[OK]%s %s %s\n' "$VERT" "$RAZ" "$1" "$2"
}
ko() {
    NB_TOTAL=$((NB_TOTAL + 1))
    printf '%s[KO]%s %s %s\n' "$ROUGE" "$RAZ" "$1" "$2"
}

nettoyer() {
    local f
    for f in "${FICHIERS_TEMP[@]}"; do
        rm -f -- "$f"
    done
}
trap nettoyer EXIT

# --- Outils ----------------------------------------------------------------------
# Lignes du CSV sans en-tête, sans \r, sans lignes vides
lignes_csv() {
    tail -n +2 "$CSV" | tr -d '\r' | grep -v '^[[:space:]]*$'
}

# Logins du CSV membres du groupe $1 (principal ou secondaire)
membres_csv() {
    lignes_csv | awk -F';' -v g="$1" '
        {
            if ($3 == g) { print $1; next }
            n = split($4, s, ",")
            for (i = 1; i <= n; i++) if (s[i] == g) { print $1; next }
        }'
}

# n-ième membre du groupe $1 dans le CSV (n = $2, 1 par défaut)
membre() {
    membres_csv "$1" | sed -n "${2:-1}p"
}

# Valeur effective d'une option sshd (sshd -T = config réellement appliquée)
sshd_val() {
    sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'
}

# peut UTILISATEUR -r|-w|-x CHEMIN : l'utilisateur a-t-il ce droit ?
# "test" utilise access(2), qui tient compte des ACL.
peut() {
    sudo -n -u "$1" test "$2" "$3" 2>/dev/null
}

home_de() {
    getent passwd "$1" | cut -d: -f6
}

# controle_acces ID UTILISATEUR GROUPE CHEMIN ATTENDU(rw|r|-)
# Sur un répertoire : lecture = r+x (lister), écriture = w+x (créer).
controle_acces() {
    local id=$1 u=$2 groupe=$3 chemin=$4 attendu=$5
    local obtenu="-"

    if [[ -z $u ]]; then
        ko "$id" "aucun membre du groupe $groupe dans comptes.csv"
        return
    fi
    if peut "$u" -r "$chemin" && peut "$u" -x "$chemin"; then
        obtenu="r"
    fi
    if peut "$u" -w "$chemin" && peut "$u" -x "$chemin"; then
        if [[ $obtenu == "r" ]]; then obtenu="rw"; else obtenu="w"; fi
    fi

    if [[ $obtenu == "$attendu" ]]; then
        ok "$id" "$groupe ($u) sur $chemin : $attendu"
    else
        ko "$id" "$groupe ($u) sur $chemin : obtenu '$obtenu', attendu '$attendu'"
    fi
}

# =============================================================================
#  C1 - comptes et groupes créés depuis comptes.csv
# =============================================================================
test_C1_groupes() {
    local g manquants=""
    for g in $( { lignes_csv | cut -d';' -f3; lignes_csv | cut -d';' -f4 | tr ',' '\n'; } | grep -v '^$' | sort -u); do
        getent group "$g" >/dev/null || manquants+="$g "
    done
    if [[ -z $manquants ]]; then
        ok "C1" "tous les groupes de comptes.csv existent"
    else
        ko "C1" "groupes manquants : $manquants"
    fi
}

test_C1_comptes() {
    local login gp gs g erreurs=""
    while IFS=';' read -r login _ gp gs; do
        if ! id -u "$login" >/dev/null 2>&1; then
            erreurs+="$login(absent) "
            continue
        fi
        [[ $(id -gn "$login") == "$gp" ]] || erreurs+="$login(groupe principal) "
        for g in ${gs//,/ }; do
            id -nG "$login" | tr ' ' '\n' | grep -qx "$g" || erreurs+="$login(pas dans $g) "
        done
    done < <(lignes_csv)
    if [[ -z $erreurs ]]; then
        ok "C1" "chaque compte du CSV existe avec les bons groupes"
    else
        ko "C1" "comptes non conformes : $erreurs"
    fi
}

test_C1_doublons() {
    local doublons
    doublons="$(getent passwd | cut -d: -f1 | sort | uniq -d)"
    if [[ -z $doublons ]]; then
        ok "C1" "aucun compte en double (script idempotent)"
    else
        ko "C1" "comptes en double : $doublons"
    fi
}

test_C1_metier() {
    local g n erreurs=""
    for g in "${GROUPES_METIER[@]}"; do
        n="$(membres_csv "$g" | wc -l)"
        (( n >= 2 )) || erreurs+="$g($n) "
    done
    if [[ -z $erreurs ]]; then
        ok "C1" "chaque groupe métier compte au moins 2 utilisateurs"
    else
        ko "C1" "groupes métier avec moins de 2 membres : $erreurs"
    fi
}

test_C1_freelance() {
    local u exp erreurs=""
    for u in $(membres_csv freelance); do
        exp="$(chage -l "$u" 2>/dev/null | awk -F': ' '/^Account expires/ {print $2}')"
        if [[ -z $exp || $exp == "never" ]]; then
            erreurs+="$u "
        fi
    done
    if [[ -z $erreurs ]]; then
        ok "C1" "les comptes freelance ont une date d'expiration"
    else
        ko "C1" "freelances sans date d'expiration : $erreurs"
    fi
}

# =============================================================================
#  C2 - répertoires de /srv, permissions et ACL (y compris par défaut)
# =============================================================================
test_C2_matrice() {
    # chemin groupe droit_attendu  (tableau du contexte A)
    local ligne chemin groupe attendu
    local -a matrice=(
        "/srv/projets dev rw"           "/srv/projets design r"
        "/srv/projets commercial -"     "/srv/projets freelance -"
        "/srv/projets/externe dev rw"   "/srv/projets/externe design r"
        "/srv/projets/externe commercial -" "/srv/projets/externe freelance rw"
        "/srv/maquettes dev r"          "/srv/maquettes design rw"
        "/srv/maquettes commercial r"   "/srv/maquettes freelance -"
        "/srv/clients dev -"            "/srv/clients design -"
        "/srv/clients commercial rw"    "/srv/clients freelance -"
    )
    for ligne in "${matrice[@]}"; do
        read -r chemin groupe attendu <<<"$ligne"
        if [[ ! -d $chemin ]]; then
            ko "C2" "$chemin n'existe pas"
            continue
        fi
        controle_acces "C2" "$(membre "$groupe")" "$groupe" "$chemin" "$attendu"
    done
}

test_C2_acl_defaut() {
    local d manquants=""
    for d in /srv/projets /srv/projets/externe /srv/maquettes /srv/clients; do
        getfacl -d -p "$d" 2>/dev/null | grep -qE '^group:[^:]+:' || manquants+="$d "
    done
    if [[ -z $manquants ]]; then
        ok "C2" "ACL par défaut présentes sur les 4 répertoires"
    else
        ko "C2" "ACL par défaut absentes sur : $manquants"
    fi
}

# Crée un vrai fichier comme un dev, puis vérifie qui peut l'utiliser :
# c'est la preuve que les ACL par défaut s'appliquent aux NOUVEAUX fichiers.
test_C2_heritage() {
    local dev1 dev2 des com f
    dev1="$(membre dev 1)"; dev2="$(membre dev 2)"
    des="$(membre design)"; com="$(membre commercial)"
    f="/srv/projets/.verif_$$"

    if ! sudo -n -u "$dev1" touch "$f" 2>/dev/null; then
        ko "C2" "$dev1 (dev) ne peut pas créer de fichier dans /srv/projets"
        return
    fi
    FICHIERS_TEMP+=("$f")

    if peut "$dev2" -w "$f"; then
        ok "C2" "nouveau fichier de $dev1 modifiable par $dev2 (dev) : héritage OK"
    else
        ko "C2" "nouveau fichier de $dev1 non modifiable par $dev2 (dev)"
    fi
    if peut "$des" -r "$f" && ! peut "$des" -w "$f"; then
        ok "C2" "nouveau fichier lisible mais non modifiable par $des (design)"
    else
        ko "C2" "droits de $des (design) incorrects sur un nouveau fichier"
    fi
    if ! peut "$com" -r "$f"; then
        ok "C2" "nouveau fichier illisible pour $com (commercial)"
    else
        ko "C2" "$com (commercial) peut lire un fichier de /srv/projets"
    fi
}

test_C2_externe() {
    local fl dev f
    fl="$(membre freelance)"; dev="$(membre dev)"
    f="/srv/projets/externe/.verif_$$"
    if sudo -n -u "$fl" touch "$f" 2>/dev/null; then
        FICHIERS_TEMP+=("$f")
        if peut "$dev" -w "$f"; then
            ok "C2" "fichier déposé par $fl (freelance) dans externe modifiable par $dev (dev)"
        else
            ko "C2" "fichier de $fl dans externe non modifiable par $dev (dev)"
        fi
    else
        ko "C2" "$fl (freelance) ne peut pas écrire dans /srv/projets/externe"
    fi
}

# =============================================================================
#  C3 - sudo
# =============================================================================
test_C3_fichier() {
    if [[ -f $SUDOERS_DST && $(stat -c '%a %U' "$SUDOERS_DST") == "440 root" ]] \
       && visudo -c >/dev/null 2>&1; then
        ok "C3" "$SUDOERS_DST présent (0440 root) et syntaxe sudo valide"
    else
        ko "C3" "$SUDOERS_DST absent, mauvais droits ou syntaxe invalide"
    fi
}

test_C3_admins() {
    local a erreurs=""
    for a in $(membres_csv admins); do
        sudo -l -U "$a" 2>/dev/null | grep -q '(ALL : ALL) ALL' || erreurs+="$a "
    done
    if [[ -z $erreurs ]]; then
        ok "C3" "les membres de admins ont tous les droits sudo"
    else
        ko "C3" "admins sans sudo complet : $erreurs"
    fi
}

test_C3_support() {
    local regles
    regles="$(sudo -l -U support 2>/dev/null | grep -E '^[[:space:]]+\(')"
    if [[ $(grep -c . <<<"$regles") -eq 1 ]] && grep -qE "NOPASSWD: ${ANALYSE}\$" <<<"$regles"; then
        ok "C3" "le compte support ne peut lancer que analyse_logs.sh"
    else
        ko "C3" "règles sudo de support incorrectes : $(tr '\n' ';' <<<"$regles")"
    fi
}

test_C3_personne_dautre() {
    local u autorises="" admins
    admins=" $(membres_csv admins | tr '\n' ' ') "
    for u in $(getent passwd | cut -d: -f1); do
        [[ $u == "root" || $u == "support" || $admins == *" $u "* ]] && continue
        if sudo -l -U "$u" 2>/dev/null | grep -q 'may run the following'; then
            autorises+="$u "
        fi
    done
    if [[ -z $autorises ]]; then
        ok "C3" "aucun autre compte n'a sudo (freelances compris)"
    else
        ko "C3" "comptes avec sudo non prévus : $autorises"
    fi
}

test_C3_script() {
    if [[ -f $ANALYSE && $(stat -c '%U' "$ANALYSE") == "root" ]] \
       && [[ -z $(find "$ANALYSE" -perm /022) ]]; then
        ok "C3" "$ANALYSE appartient à root et n'est modifiable que par lui"
    else
        ko "C3" "$ANALYSE absent ou modifiable par un autre que root"
    fi
}

# =============================================================================
#  C4 - root verrouillé, répertoires personnels privés
# =============================================================================
test_C4_root() {
    if [[ $(passwd -S root 2>/dev/null | awk '{print $2}') == "L" ]]; then
        ok "C4" "le compte root est verrouillé"
    else
        ko "C4" "le compte root n'est pas verrouillé (passwd -S root)"
    fi
}

test_C4_homes() {
    local ouverts
    ouverts="$(find /home -mindepth 1 -maxdepth 1 -type d -perm /077 2>/dev/null | tr '\n' ' ')"
    if [[ -z $ouverts ]]; then
        ok "C4" "tous les répertoires de /home sont en 0700"
    else
        ko "C4" "répertoires personnels accessibles à d'autres : $ouverts"
    fi
}

test_C4_lecture_home() {
    local com dev
    com="$(membre commercial)"; dev="$(membre dev)"
    if ! peut "$com" -r "$(home_de "$dev")"; then
        ok "C4" "$com (commercial) ne peut pas lire le home de $dev"
    else
        ko "C4" "$com (commercial) peut lire le home de $dev"
    fi
}

# =============================================================================
#  S1 à S5 - SSH (sshd -T affiche la configuration RÉELLEMENT appliquée)
# =============================================================================
test_S1_mdp() {
    if [[ $(sshd_val passwordauthentication) == "no" && $(sshd_val kbdinteractiveauthentication) == "no" ]]; then
        ok "S1" "authentification par mot de passe refusée"
    else
        ko "S1" "mot de passe encore accepté (PasswordAuthentication / KbdInteractiveAuthentication)"
    fi
}

test_S1_cle() {
    if [[ $(sshd_val pubkeyauthentication) == "yes" && $(sshd_val authenticationmethods) == "publickey" ]]; then
        ok "S1" "authentification par clé uniquement"
    else
        ko "S1" "PubkeyAuthentication / AuthenticationMethods incorrects"
    fi
}

test_S2() {
    if [[ $(sshd_val permitrootlogin) == "no" ]]; then
        ok "S2" "connexion root refusée"
    else
        ko "S2" "PermitRootLogin vaut '$(sshd_val permitrootlogin)' (attendu : no)"
    fi
}

test_S3_allowgroups() {
    if [[ $(sshd_val allowgroups) == "acces_ssh" ]]; then
        ok "S3" "seul le groupe acces_ssh peut se connecter"
    else
        ko "S3" "AllowGroups vaut '$(sshd_val allowgroups)' (attendu : acces_ssh)"
    fi
}

test_S3_cles() {
    local u h erreurs=""
    for u in $(membres_csv acces_ssh); do
        h="$(home_de "$u")"
        if [[ ! -s $h/.ssh/authorized_keys ]]; then
            erreurs+="$u(pas de clé) "
        elif [[ $(stat -c '%a %U' "$h/.ssh/authorized_keys") != "600 $u" \
                || $(stat -c '%a' "$h/.ssh") != "700" ]]; then
            erreurs+="$u(droits) "
        fi
    done
    if [[ -z $erreurs ]]; then
        ok "S3" "clés publiques installées pour tous les comptes de acces_ssh"
    else
        ko "S3" "problèmes de clés : $erreurs"
    fi
}

test_S3_non_autorises() {
    local u intrus=""
    for u in $(membres_csv dev) $(membres_csv design) $(membres_csv commercial) $(membres_csv freelance); do
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx acces_ssh && intrus+="$u "
    done
    if [[ -z $intrus ]]; then
        ok "S3" "aucun utilisateur métier dans acces_ssh"
    else
        ko "S3" "utilisateurs métier avec accès SSH : $intrus"
    fi
}

test_S4_essais() {
    local n
    n="$(sshd_val maxauthtries)"
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 4 )); then
        ok "S4" "au plus 4 essais d'authentification (MaxAuthTries $n)"
    else
        ko "S4" "MaxAuthTries vaut '$n' (attendu : 1 à 4)"
    fi
}

test_S4_inactivite() {
    local intervalle nb total tmout
    intervalle="$(sshd_val clientaliveinterval)"
    nb="$(sshd_val clientalivecountmax)"
    total=$(( ${intervalle:-0} * ${nb:-0} ))
    tmout="$(grep -Eo 'TMOUT=[0-9]+' /etc/profile.d/tmout.sh 2>/dev/null | cut -d= -f2)"

    if (( total > 0 && total <= 900 )); then
        ok "S4" "connexion morte fermée après ${total}s (ClientAlive*)"
    else
        ko "S4" "ClientAliveInterval x ClientAliveCountMax = ${total}s (attendu : 1 à 900)"
    fi
    if [[ -n $tmout ]] && (( tmout > 0 && tmout <= 900 )); then
        ok "S4" "shell inactif fermé après ${tmout}s (TMOUT)"
    else
        ko "S4" "TMOUT absent ou supérieur à 900 s dans /etc/profile.d/tmout.sh"
    fi
}

test_S5_fichier() {
    if [[ ! -f $SSHD_CONF_DST ]]; then
        ko "S5" "$SSHD_CONF_DST absent"
    elif [[ -f $SSHD_CONF_SRC ]] && ! cmp -s "$SSHD_CONF_SRC" "$SSHD_CONF_DST"; then
        ko "S5" "$SSHD_CONF_DST différent de la version du dépôt (modifié ?)"
    else
        ok "S5" "configuration placée dans /etc/ssh/sshd_config.d/ et identique au dépôt"
    fi
}

test_S5_syntaxe() {
    if sshd -t >/dev/null 2>&1; then
        ok "S5" "sshd -t : configuration SSH valide"
    else
        ko "S5" "sshd -t signale une erreur de configuration"
    fi
}

# A FAIRE séance 4 : test_J1..., test_J2..., test_J3..., test_J4..., test_D1...
# A FAIRE séance 5 : test_B1..., test_B2..., test_B3..., test_B4..., test_D2..., test_D3...

# =============================================================================
#  Programme principal
# =============================================================================
main() {
    if [[ $# -gt 1 ]]; then
        echo "Usage : sudo bash $0 [FILTRE]   (ex. : S, C2)" >&2
        exit 2
    fi
    if [[ $EUID -ne 0 ]]; then
        echo "verifier.sh doit être lancé en root (sudo bash verifier.sh)" >&2
        exit 2
    fi
    if [[ ! -r $CSV ]]; then
        echo "comptes.csv introuvable : $CSV" >&2
        exit 2
    fi

    local t
    # declare -F liste les fonctions définies ; on garde celles qui commencent
    # par test_ (et par test_<FILTRE> si un filtre est donné)
    for t in $(declare -F | awk '{print $3}' | grep "^test_${FILTRE}"); do
        "$t"
    done

    echo "--- $NB_OK / $NB_TOTAL tests réussis"
    if (( NB_OK == NB_TOTAL )); then
        exit 0
    fi
    exit 1
}

main "$@"
