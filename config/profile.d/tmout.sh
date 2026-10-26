# shellcheck shell=sh
# /etc/profile.d/tmout.sh - complète l'exigence S4
# Ferme automatiquement un shell resté inactif 10 minutes (600 s).
# ClientAliveInterval (sshd) ne coupe que les connexions mortes : un client
# PuTTY ouvert mais inutilisé répond aux sondes et resterait connecté.
# readonly empêche l'utilisateur de désactiver ce délai.
if [ "${TMOUT:-}" != "600" ]; then
    TMOUT=600
    readonly TMOUT
    export TMOUT
fi
