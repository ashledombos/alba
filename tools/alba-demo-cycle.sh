#!/bin/bash
# Alba — cycle de démo upgrade/rollback atomique, end-to-end.
# Prérequis : localhost/alba-base déjà buildée (bash build-base.sh).
#   1. build demo v1/v2 (FROM alba-base, sshd + marqueur de version)
#   2. registry local :5000 + push v1/v2
#   3. install v1 → output/alba.raw (tools/alba-install.sh : grub.cfg 1er boot OK)
#   4. boot VM (SeaBIOS) → v1 ; bootc switch v2 → reboot → v2 ;
#      bootc rollback → reboot → v1.
# Usage : bash tools/alba-demo-cycle.sh [--uefi]
set -e
cd /var/home/machine/alba
D=demo
UEFI=${1:-}

SSHVM(){ ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p 2222 root@localhost "$@"; }
waitssh(){ for i in $(seq 1 45); do SSHVM true 2>/dev/null && return 0; sleep 4; done; return 1; }
bootvm(){
  podman rm -f albavm 2>/dev/null || true; sleep 1
  local fw=()
  if [ "$UEFI" = "--uefi" ]; then
    fw=(-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd
        -drive if=pflash,format=raw,file=/tmp/VARS.fd)
    podman run -d --name albavm --network=host --security-opt label=disable --device /dev/kvm --group-add keep-groups \
      -v /var/home/machine/alba/output:/vm localhost/alba-qemu bash -c "
      cp /usr/share/edk2/ovmf/OVMF_VARS.fd /tmp/VARS.fd
      exec qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 4096 \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file=/tmp/VARS.fd \
        -drive file=/vm/alba.raw,if=virtio,format=raw \
        -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 -display none" >/dev/null
  else
    podman run -d --name albavm --network=host --security-opt label=disable --device /dev/kvm --group-add keep-groups \
      -v /var/home/machine/alba/output:/vm localhost/alba-qemu \
      qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 4096 \
        -drive file=/vm/alba.raw,if=virtio,format=raw \
        -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 -display none >/dev/null
  fi
}

echo "########## 1. build demo v1 + v2 (FROM alba-base)"
podman build --security-opt label=disable --build-arg ALBA_VER=1 -t localhost/alba-demo:v1 -f $D/Containerfile.demo $D 2>&1 | tail -1
podman build --security-opt label=disable --build-arg ALBA_VER=2 -t localhost/alba-demo:v2 -f $D/Containerfile.demo $D 2>&1 | tail -1

echo "########## 2. registry + push"
podman ps --format '{{.Names}}' | grep -qx albareg || podman run -d --name albareg -p 5000:5000 -v /var/home/machine/alba/reg:/var/lib/registry docker.io/library/registry:2 >/dev/null
sleep 2
podman push --tls-verify=false localhost/alba-demo:v1 localhost:5000/alba:v1 2>&1 | tail -1
podman push --tls-verify=false localhost/alba-demo:v2 localhost:5000/alba:v2 2>&1 | tail -1

echo "########## 3. install v1 (alba-install.sh)"
bash tools/alba-install.sh localhost/alba-demo:v1 2>&1 | tail -3

echo "########## 4. boot v1 ${UEFI:+(UEFI/OVMF)}"
bootvm
waitssh && echo "SSH OK" || { echo "SSH KO boot v1"; exit 1; }
echo "===== version bootée (attendu 1) ====="; SSHVM 'cat /etc/alba-version; systemctl is-system-running || true'

echo "########## 5. bootc switch -> v2"
SSHVM 'bootc switch 10.0.2.2:5000/alba:v2 2>&1 | tail -4'
SSHVM 'systemctl reboot' 2>/dev/null || true; sleep 20
waitssh && echo "SSH OK post-upgrade" || { echo "SSH KO post-upgrade"; exit 1; }
echo "===== version bootée après upgrade (attendu 2) ====="; SSHVM 'cat /etc/alba-version'
SSHVM 'echo "menuentries: $(grep -c ^menuentry /boot/grub2/grub.cfg)"'

echo "########## 6. bootc rollback -> v1"
SSHVM 'bootc rollback 2>&1 | tail -3'
SSHVM 'systemctl reboot' 2>/dev/null || true; sleep 20
waitssh && echo "SSH OK post-rollback" || { echo "SSH KO post-rollback"; exit 1; }
echo "===== version bootée après rollback (attendu 1) ====="; SSHVM 'cat /etc/alba-version'
echo "########## DÉMO TERMINÉE (${UEFI:-BIOS})"
