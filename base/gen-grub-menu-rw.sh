#!/bin/bash
# Alba — remonte /boot en écriture le temps de régénérer grub.cfg, puis le
# repasse en lecture seule. Appelé au boot (rattrapage) et à l'extinction
# (ExecStop) : après un « bootc upgrade », l'entrée BLS du nouveau déploiement
# est déjà posée, donc le grub.cfg régénéré à l'arrêt pointe la bonne version
# au prochain démarrage.
set -uo pipefail
BOOT=/boot
remounted=0
if findmnt -no OPTIONS "$BOOT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
  mount -o remount,rw "$BOOT" 2>/dev/null && remounted=1
fi
/usr/lib/alba/gen-grub-menu.sh "$BOOT"
rc=$?
[ "$remounted" = 1 ] && mount -o remount,ro "$BOOT" 2>/dev/null || true
exit $rc
