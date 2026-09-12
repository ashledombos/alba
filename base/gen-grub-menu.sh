#!/bin/bash
# Alba — génère /boot/grub2/grub.cfg avec des menuentries EXPLICITES à partir des
# entrées Boot Loader Spec (/boot/loader/entries/*.conf), SANS dépendre de la
# commande blscfg/blsuki de grub (absente en grub 2.12) NI de grub2-mkconfig
# (dont grub2-probe échoue sur une racine composefs). Indépendant de la version.
# Les entrées sont triées par « version » BLS décroissante : le déploiement le
# plus récent est le défaut (entrée 0), comme le fait ostree/blscfg.
set -euo pipefail
BOOT="${1:-/boot}"
CFG="$BOOT/grub2/grub.cfg"
BUUID=""
[ -f "$BOOT/grub2/bootuuid.cfg" ] && \
  BUUID=$(sed -n 's/.*BOOT_UUID="\([^"]*\)".*/\1/p' "$BOOT/grub2/bootuuid.cfg")

# Trier les entrées par version décroissante (champ « version N » du BLS).
# Repli sur le nom de fichier si le champ manque.
mapfile -t ENTRIES < <(
  for e in "$BOOT"/loader/entries/*.conf; do
    [ -f "$e" ] || continue
    v=$(sed -n 's/^version[[:space:]]\+//p' "$e" | head -1)
    printf '%s\t%s\n' "${v:-0}" "$e"
  done | sort -t $'\t' -k1,1rn -k2,2r | cut -f2-
)

tmp="$CFG.alba.new"
{
  echo "# Généré par Alba (gen-grub-menu.sh) — entrées explicites, sans blscfg"
  echo "set timeout=5"
  echo "set timeout_style=menu"
  echo "insmod all_video"
  echo "insmod gzio"
  echo "insmod part_gpt"
  echo "insmod ext2"
  if [ -n "$BUUID" ]; then
    echo "search --no-floppy --fs-uuid --set=root $BUUID"
  else
    echo "search --no-floppy --label --set=root root"
  fi
  echo "set default=0"
  for e in "${ENTRIES[@]}"; do
    [ -f "$e" ] || continue
    title=$(sed -n 's/^title //p' "$e")
    lin=$(sed -n 's/^linux //p' "$e")
    ini=$(sed -n 's/^initrd //p' "$e")
    opt=$(sed -n 's/^options //p' "$e")
    [ -n "$lin" ] || continue
    echo "menuentry '${title:-Alba}' {"
    echo "  linux $lin $opt"
    [ -n "$ini" ] && echo "  initrd $ini"
    echo "}"
  done
} > "$tmp"
mv -f "$tmp" "$CFG"
