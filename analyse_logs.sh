#!/usr/bin/env bash
# =============================================================================
# analyse_logs.sh - Exigence J4 (séance 4)
# VERSION PROVISOIRE : elle existe dès la séance 3 pour que la règle sudo du
# compte support (C3) pointe vers un vrai fichier. Le rapport SSH sera écrit
# en séance 4.
# Installé par installer.sh dans /usr/local/sbin/ (root:root, 0755).
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "analyse_logs.sh : ce script doit être lancé en root (sudo)" >&2
    exit 1
fi

echo "analyse_logs.sh : rapport des connexions SSH à implémenter (séance 4)"
exit 0
