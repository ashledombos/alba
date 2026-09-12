#!/bin/bash
# Alba — image Plasma complète : couche desktop → disque bootable → qcow2 export.
# Prérequis : localhost/alba-base buildée (bash build-base.sh).
#   1. build de la couche Plasma (FROM alba-base)
#   2. install → output/alba.raw (tools/alba-install.sh : grub.cfg 1er boot OK)
#   3. conversion qcow2 compressé → output/alba-plasma.qcow2
# Boot du qcow2 : BIOS/SeaBIOS (ou UEFI grâce au fallback BOOTX64.EFI), Secure Boot off.
set -e
cd /var/home/machine/alba

echo "### 1/3 build couche Plasma"
podman build --security-opt label=disable -t localhost/alba-plasma \
  -f alba/Containerfile.alba alba > /tmp/build-plasma.log 2>&1 || { tail -20 /tmp/build-plasma.log; exit 1; }
grep -E "Checks|Warning" /tmp/build-plasma.log | tail -3
podman images localhost/alba-plasma --format "image Plasma : {{.Size}}"

echo "### 2/3 install → alba.raw"
bash tools/alba-install.sh localhost/alba-plasma 2>&1 | tail -3

echo "### 3/3 qcow2 compressé"
rm -f output/alba-plasma.qcow2
podman run --rm --security-opt label=disable -v /var/home/machine/alba:/work localhost/omv-builder bash -c '
  command -v qemu-img >/dev/null 2>&1 || dnf install -y qemu-img >/dev/null 2>&1
  qemu-img convert -f raw -O qcow2 -c /work/output/alba.raw /work/output/alba-plasma.qcow2'
echo "TAILLES : raw=$(du -h output/alba.raw | cut -f1)  qcow2=$(du -h output/alba-plasma.qcow2 | cut -f1)"
sha256sum output/alba-plasma.qcow2
echo "### DONE"
