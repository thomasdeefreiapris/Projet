#!/usr/bin/env bash
# =============================================================================
# installer.sh - reconstruit toute la configuration sur la VM vierge
#
# Usage  : en root, depuis n'importe où :  bash /chemin/du/depot/installer.sh
# Sortie : 0 = succès, 1 = pas root / dépôt incomplet, 3 = sécurité (risque
#          de se retrouver bloqué hors de la VM), 4 = config invalide
#
# Peut être relancé sans danger : chaque étape vérifie l'état avant d'agir.
#
# État : séance 3 (C1-C4, S1-S5). Les étapes des séances 4 et 5 sont
# indiquées par "A FAIRE" et seront ajoutées au fur et à mesure.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$REPO_DIR/config"
CSV="$REPO_DIR/comptes.csv"

# Séance 4 : ajouter fail2ban nftables unattended-upgrades
# Séance 5 : ajouter rsync
PAQUETS=(sudo acl openssh-server)

SSHD_CONF_SRC="$CONFIG/ssh/sshd_config.d/10-durcissement.conf"
SSHD_CONF_DST="/etc/ssh/sshd_config.d/10-durcissement.conf"
SUDOERS_SRC="$CONFIG/sudoers.d/projet"
SUDOERS_DST="/etc/sudoers.d/projet"

etape() { echo; echo "=== $* ==="; }
log()   { echo "[installer] $*"; }
err()   { echo "[installer] ERREUR : $*" >&2; }

# --- Vérifications ---------------------------------------------------------------
verifier_prerequis() {
    if [[ $EUID -ne 0 ]]; then
        err "ce script doit être lancé en root (su - puis bash installer.sh)"
        exit 1
    fi
    local f
    for f in "$CSV" "$REPO_DIR/creer_comptes.sh" "$REPO_DIR/analyse_logs.sh" \
             "$SSHD_CONF_SRC" "$SUDOERS_SRC" "$CONFIG/profile.d/tmout.sh"; do
        if [[ ! -f $f ]]; then
            err "fichier manquant dans le dépôt : $f"
            exit 1
        fi
    done
}

# Logins du CSV appartenant au groupe $1 (principal ou secondaire)
membres_csv() {
    tail -n +2 "$CSV" | tr -d '\r' | awk -F';' -v g="$1" '
        NF == 4 {
            if ($3 == g) { print $1; next }
            n = split($4, s, ",")
            for (i = 1; i <= n; i++) if (s[i] == g) { print $1; next }
        }'
}

# --- Étapes ----------------------------------------------------------------------
installer_paquets() {
    etape "Paquets"
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${PAQUETS[@]}"
}

configurer_hosts() {
    etape "Nom de la machine dans /etc/hosts"
    # sudo résout le nom de la machine à chaque appel : s'il n'est pas dans
    # /etc/hosts, chaque sudo attend un délai DNS (verifier.sh devient très lent).
    local nom
    nom="$(hostname)"
    if ! grep -qE "^[0-9.]+[[:space:]].*\b${nom}\b" /etc/hosts; then
        printf '127.0.1.1\t%s\n' "$nom" >>/etc/hosts
        log "$nom ajouté à /etc/hosts"
    else
        log "$nom déjà présent dans /etc/hosts"
    fi
}

configurer_login_defs() {
    etape "Répertoires personnels créés en 0700 (C4)"
    # Les futurs comptes créés par useradd auront un home en 0700
    if grep -qE '^[[:space:]]*HOME_MODE' /etc/login.defs; then
        sed -i -E 's/^[[:space:]]*HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >>/etc/login.defs
    fi
    log "HOME_MODE 0700 dans /etc/login.defs"
}

installer_scripts() {
    etape "Scripts lancés en root"
    # Appartient à root, modifiable seulement par root (règle sudo de support)
    install -m 0755 -o root -g root "$REPO_DIR/analyse_logs.sh" /usr/local/sbin/analyse_logs.sh
    log "analyse_logs.sh -> /usr/local/sbin/ (root:root 0755)"
}

configurer_sudo() {
    etape "sudo (C3)"
    # 1. On valide la syntaxe AVANT de copier : un sudoers cassé bloque sudo
    if ! visudo -cf "$SUDOERS_SRC" >/dev/null; then
        err "syntaxe invalide dans $SUDOERS_SRC"
        exit 4
    fi
    install -m 0440 -o root -g root "$SUDOERS_SRC" "$SUDOERS_DST"
    visudo -c >/dev/null
    log "$SUDOERS_DST installé"

    # 2. "Aucun autre compte n'a sudo" : on vide le groupe sudo de Debian
    local membres m
    membres="$(getent group sudo | cut -d: -f4 | tr ',' ' ')"
    for m in $membres; do
        gpasswd -d "$m" sudo >/dev/null
        log "$m retiré du groupe sudo"
    done
}

lancer_creer_comptes() {
    etape "Comptes, groupes, /srv et ACL (C1, C2)"
    bash "$REPO_DIR/creer_comptes.sh" "$CSV"
}

verrouiller_comptes_hors_csv() {
    etape "Comptes humains absents de comptes.csv"
    # Exemple : le compte créé pendant l'installation de Debian.
    # On ne le supprime pas (on garderait ses fichiers sans propriétaire),
    # on le neutralise : mot de passe verrouillé, compte expiré, pas de shell.
    local login uid logins_csv
    # Liste lue UNE fois dans une variable : avec "set -o pipefail", un
    # "... | grep -q" peut échouer à tort (SIGPIPE quand grep s'arrête tôt).
    logins_csv="$(tail -n +2 "$CSV" | tr -d '\r' | cut -d';' -f1)"
    while IFS=: read -r login _ uid _; do
        if (( uid >= 1000 && uid < 60000 )); then
            if ! grep -qx "$login" <<<"$logins_csv"; then
                passwd -l "$login" >/dev/null
                chage -E 0 "$login"
                usermod -s /usr/sbin/nologin "$login"
                log "$login : verrouillé (absent du CSV)"
            fi
        fi
    done </etc/passwd
}

proteger_homes() {
    etape "Répertoires personnels existants en 0700 (C4)"
    local d
    for d in /home/*/; do
        [[ -d $d ]] || continue
        chmod 0700 "$d"
    done
    log "chmod 0700 appliqué à /home/*"
}

definir_mdp_admins() {
    etape "Mots de passe des administrateurs (sudo + console de secours)"
    # Les mots de passe ne sont JAMAIS dans le dépôt : ils sont saisis ici.
    local admin statut
    for admin in $(membres_csv admins); do
        statut="$(passwd -S "$admin" | awk '{print $2}')"
        if [[ $statut == "P" ]]; then
            log "$admin : mot de passe déjà défini"
        elif [[ -t 0 ]]; then
            echo "Choisis le mot de passe de $admin :"
            until passwd "$admin"; do
                echo "Échec, recommence."
            done
        else
            log "ATTENTION : $admin n'a pas de mot de passe (lancer : passwd $admin)"
        fi
    done
}

configurer_profile() {
    etape "Déconnexion des shells inactifs (S4)"
    install -m 0644 -o root -g root "$CONFIG/profile.d/tmout.sh" /etc/profile.d/tmout.sh
    log "/etc/profile.d/tmout.sh installé"
}

# Garde-fou : au moins un admin doit pouvoir entrer par SSH avec une clé.
au_moins_un_admin_avec_cle() {
    local admin home
    for admin in $(membres_csv admins); do
        home="$(getent passwd "$admin" | cut -d: -f6)" || continue
        if [[ -s $home/.ssh/authorized_keys ]]; then
            return 0
        fi
    done
    return 1
}

configurer_ssh() {
    etape "SSH (S1 à S5)"
    if ! au_moins_un_admin_avec_cle; then
        err "aucun administrateur n'a de clé dans config/cles/ : on n'applique PAS"
        err "la config SSH (vous seriez bloqués dehors). Ajoutez config/cles/<login>.pub"
        exit 3
    fi

    local sauvegarde=""
    if [[ -f $SSHD_CONF_DST ]]; then
        sauvegarde="$(mktemp)"
        cp -p "$SSHD_CONF_DST" "$sauvegarde"
    fi
    install -m 0644 -o root -g root "$SSHD_CONF_SRC" "$SSHD_CONF_DST"

    # S5 : on valide TOUTE la configuration avant de redémarrer
    if ! sshd -t; then
        err "sshd -t a échoué : retour à la configuration précédente"
        if [[ -n $sauvegarde ]]; then
            cp -p "$sauvegarde" "$SSHD_CONF_DST"
        else
            rm -f "$SSHD_CONF_DST"
        fi
        exit 4
    fi
    if [[ -n $sauvegarde ]]; then
        rm -f "$sauvegarde"
    fi

    systemctl restart ssh
    log "sshd -t OK, service ssh redémarré"
}

verrouiller_root() {
    etape "Verrouillage de root (C4)"
    # Garde-fou : un admin doit avoir un mot de passe (sinon plus de sudo)
    local admin ok=0
    for admin in $(membres_csv admins); do
        if [[ $(passwd -S "$admin" | awk '{print $2}') == "P" ]]; then
            ok=1
        fi
    done
    if [[ $ok -eq 0 ]]; then
        err "aucun admin n'a de mot de passe : root n'est PAS verrouillé"
        exit 3
    fi
    passwd -l root >/dev/null
    log "compte root verrouillé"
}

# --- Programme principal -----------------------------------------------------------
main() {
    verifier_prerequis
    installer_paquets
    configurer_hosts
    configurer_login_defs
    installer_scripts
    configurer_sudo
    lancer_creer_comptes
    verrouiller_comptes_hors_csv
    proteger_homes
    definir_mdp_admins
    configurer_profile
    configurer_ssh
    # A FAIRE séance 4 : fail2ban (J1), nftables (J2), journald (J3), unattended-upgrades (D1)
    # A FAIRE séance 5 : second disque, sauvegarde.sh + planification (B1-B3)
    verrouiller_root   # toujours en dernier
    etape "Terminé : lancer maintenant  bash $REPO_DIR/verifier.sh"
}

main "$@"
