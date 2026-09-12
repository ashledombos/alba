#!/bin/bash
# Alba — génère les manifestes systemd que bootc lint exige d'une image bootc.
# S'exécute DANS le build de l'image (base et couches dérivées : à relancer
# après tout useradd/groupadd ou ajout de paquets qui peuple /var).
#
#  - /usr/lib/sysusers.d/alba-image.conf : toute entrée de /etc/passwd et
#    /etc/group sans définition sysusers.d (lint « sysusers »).
#  - /usr/lib/tmpfiles.d/alba-var.conf : tout répertoire/symlink de /var non
#    couvert par tmpfiles.d (lint « var-tmpfiles »). Les FICHIERS de /var ne
#    sont pas recréables par tmpfiles : ils sont supprimés/déplacés ici même
#    (rpmdb → /usr/lib/sysimage/rpm, catalog/random-seed régénérés au boot).
set -euo pipefail

# --- fichiers de /var non recréables -------------------------------------
# rpmdb : déplacé dans /usr (immuable, cohérent image-mode : les paquets ne
# changent qu'au build). Le symlink assure rpm/dnf au build des couches
# dérivées ; au boot c'est tmpfiles qui le recrée dans le /var machine-local.
if [ -d /var/lib/rpm ] && [ ! -L /var/lib/rpm ]; then
    mkdir -p /usr/lib/sysimage
    rm -rf /usr/lib/sysimage/rpm
    mv /var/lib/rpm /usr/lib/sysimage/rpm
    ln -snf ../../usr/lib/sysimage/rpm /var/lib/rpm
fi
rm -f /var/db/Makefile \
      /var/lib/systemd/catalog/database \
      /var/lib/systemd/random-seed
# /var/roothome/.ssh : créé tardivement (bootc container lint lui-même le fait
# apparaître APRÈS ce script) → on le retire s'il traîne d'une couche
# précédente ET on émet une entrée statique plus bas pour le couvrir.
rm -rf /var/roothome/.ssh
# tout autre fichier résiduel signalé : cache/log de dnf, etc.
find /var/cache /var/log -mindepth 1 -delete 2>/dev/null || true

# --- sysusers -------------------------------------------------------------
covered_u=$(systemd-sysusers --cat-config 2>/dev/null | awk '$1 ~ /^u!?$/ {print $2}' | sort -u)
covered_g=$(systemd-sysusers --cat-config 2>/dev/null | awk '$1 == "g" {print $2}' | sort -u)
{
    echo "# Généré par Alba (gen-image-manifests.sh) — couverture sysusers de l'image"
    while IFS=: read -r name _ gid _; do
        grep -qxF "$name" <<<"$covered_g" && continue
        grep -qxF "$name" <<<"$covered_u" && continue   # groupe implicite d'une entrée u
        printf 'g %s %s\n' "$name" "$gid"
    done < /etc/group
    while IFS=: read -r name _ uid gid gecos home shell; do
        grep -qxF "$name" <<<"$covered_u" && continue
        printf 'u %s %s:%s "%s" %s %s\n' \
            "$name" "$uid" "$gid" "${gecos:--}" "${home:-/}" "${shell:-/usr/sbin/nologin}"
    done < /etc/passwd
} > /usr/lib/sysusers.d/alba-image.conf

# --- tmpfiles pour /var ----------------------------------------------------
covered_p=$(systemd-tmpfiles --cat-config 2>/dev/null \
    | awk '$1 !~ /^#/ && NF >= 2 {print $2}' | sed 's:/$::' | sort -u)
{
    echo "# Généré par Alba (gen-image-manifests.sh) — contenu de /var de l'image"
    # couverture statique des artefacts créés APRÈS ce script (cf. plus haut)
    echo "d /var/roothome/.ssh 0700 root root - -"
    find /var -mindepth 1 \( -type d -o -type l \) | sort | while read -r p; do
        grep -qxF "$p" <<<"$covered_p" && continue
        if [ -L "$p" ]; then
            printf 'L %s - - - - %s\n' "$p" "$(readlink "$p")"
        else
            m=$(stat -c '%a' "$p"); [ ${#m} -eq 3 ] && m="0$m"
            printf 'd %s %s %s %s - -\n' "$p" "$m" "$(stat -c '%U' "$p")" "$(stat -c '%G' "$p")"
        fi
    done
} > /usr/lib/tmpfiles.d/alba-var.conf

echo "gen-image-manifests: $(grep -vc '^#' /usr/lib/sysusers.d/alba-image.conf) sysusers, $(grep -vc '^#' /usr/lib/tmpfiles.d/alba-var.conf) tmpfiles"
