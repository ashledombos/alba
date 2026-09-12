#!/bin/bash
# Alba — pipeline d'install : image OCI → disque raw bootable, grub.cfg correct
# dès le PREMIER boot (aucune retouche manuelle).
#
# Usage (sur clairdelune) : bash alba-install.sh [IMAGE]
#   IMAGE = image bootc à installer (défaut : localhost/alba-base)
#
# Étapes :
#   1. tag IMAGE → localhost/alba-base + podman save (le wrapper root recharge
#      depuis le tar : le storage rootless de `machine` n'est pas visible de root) ;
#   2. sudo /usr/local/bin/alba-imgbuild : bootc install to-disk --via-loopback
#      --generic-image --wipe --filesystem ext4 → output/alba.raw ;
#   3. régénération OFFLINE du grub.cfg : bootc install écrit le grub.cfg statique
#      blscfg de bootupd, cassé sur le grub 2.12 d'OMV (ni blscfg ni blsuki).
#      On extrait la partition root (offset lu dans la GPT via partx, jamais codé
#      en dur), on lit les entrées BLS dans /boot/loader.N/entries (« loader » est
#      un symlink que debugfs rdump ne suit pas), on regénère un menu explicite
#      avec gen-grub-menu.sh et on le réécrit via debugfs.
#      Aux boots suivants, le drop-in ExecStop d'ostree-finalize-staged et
#      alba-grub-menu.service entretiennent le menu.
set -euo pipefail
cd /var/home/machine/alba
IMG="${1:-localhost/alba-base}"

echo "### alba-install 1/3 — image → tar ($IMG)"
[ "$IMG" = localhost/alba-base ] || podman tag "$IMG" localhost/alba-base
rm -f alba-base.tar
podman save -o alba-base.tar localhost/alba-base

echo "### alba-install 2/3 — bootc install to-disk"
sudo /usr/local/bin/alba-imgbuild 2>&1 | tail -3

echo "### alba-install 3/3 — grub.cfg du 1er boot (offline)"
S=$(partx -g -o START -n 3:3 output/alba.raw | tr -d ' ')
[ -n "$S" ] && [ "$S" -gt 0 ] || { echo "ERREUR: partition 3 introuvable dans alba.raw"; exit 1; }
dd if=output/alba.raw of=output/root.img bs=512 skip="$S" status=none
podman run --rm --security-opt label=disable \
  -v /var/home/machine/alba:/work localhost/omv-builder bash -ec '
  command -v debugfs >/dev/null 2>&1 || dnf install -y e2fsprogs >/dev/null 2>&1
  R=/work/output/root.img
  rm -rf /tmp/b; mkdir -p /tmp/b/loader /tmp/b/grub2
  for n in 1 0 2 3; do
    if debugfs -R "ls /boot/loader.$n/entries" "$R" 2>/dev/null | grep -q conf; then
      debugfs -R "rdump /boot/loader.$n/entries /tmp/b/loader" "$R" >/dev/null 2>&1
      break
    fi
  done
  ls /tmp/b/loader/entries/*.conf >/dev/null 2>&1 \
    || { echo "ERREUR: aucune entrée BLS trouvée dans /boot/loader.N/entries"; exit 1; }
  debugfs -R "dump /boot/grub2/bootuuid.cfg /tmp/b/grub2/bootuuid.cfg" "$R" >/dev/null 2>&1
  bash /work/base/gen-grub-menu.sh /tmp/b
  debugfs -w -R "rm /boot/grub2/grub.cfg" "$R" >/dev/null 2>&1
  debugfs -w -R "write /tmp/b/grub2/grub.cfg /boot/grub2/grub.cfg" "$R" >/dev/null 2>&1
  echo "menuentries écrites : $(grep -c ^menuentry /tmp/b/grub2/grub.cfg)"
'
dd if=output/root.img of=output/alba.raw bs=512 seek="$S" conv=notrunc status=none
rm -f output/root.img
echo "### alba-install DONE — output/alba.raw prêt à booter (BIOS/SeaBIOS)"
