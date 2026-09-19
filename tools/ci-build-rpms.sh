#!/bin/bash
# Alba — build des 6 briques RPM, destiné à tourner DANS un conteneur
# openmandriva/cooker (CI GitHub Actions ou n'importe quel hôte x86_64).
#
# C'est la version « runner jetable » des build-<brique>.sh de clairdelune :
# ni wrapper sudo dédié, ni slice systemd, ni image localhost/omv-builder
# pré-construite. Le conteneur EST le builder : on l'outille au début, on
# construit dans /work/rpmbuild, on dépose les RPM dans /work/rpms qui sert de
# dépôt local (createrepo_c) pour les briques suivantes et pour l'image.
#
# Usage : podman run --rm -v "$PWD:/work" -w /work docker.io/openmandriva/cooker:x86_64 \
#             bash tools/ci-build-rpms.sh
#
# Ordre IMPOSÉ : composefs avant ostree (qui exige lib64composefs-devel),
# puis bootc (exige ostree >= 2025.3), bootupd, skopeo, shim.
set -euo pipefail

WORK="${WORK:-/work}"
RPMS="$WORK/rpms"
TOPDIR="$WORK/rpmbuild"
BRICKS="${BRICKS:-composefs ostree bootc bootupd skopeo shim}"

mkdir -p "$RPMS" "$TOPDIR"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}

echo "=== outillage du conteneur cooker ==="
# Pièges OMV connus : rpm-build ne tire NI make NI gcc ; lib64atomic-devel est
# requis par plusieurs briques (-latomic_asneeded) ; dnf5-plugins n'existe pas
# (builddep est natif à dnf5). go-md2man sert aux manpages de bootc/composefs.
dnf --refresh -y install \
    rpm-build rpmdevtools createrepo_c patch tar zstd python3 \
    make gcc lib64atomic-devel rust cargo go-md2man

# --- diagnostic toolchain --------------------------------------------------
# Le lien de libostree a échoué en CI avec « ld.lld: error: <objet 64 bits> is
# incompatible with elf32-i386 » : lld a retenu une cible 32 bits alors que
# tous les objets sont en 64 bits. La seule anomalie de la ligne de lien est
# « -L/usr/lib -larchive » (sur OMV x86_64, /usr/lib est le répertoire 32 bits,
# le 64 bits vit dans /usr/lib64). On mesure donc l'état réel du conteneur
# plutôt que de corriger à l'aveugle. Purement informatif : n'interrompt rien.
diagnostic_toolchain() {
    echo "=== diagnostic toolchain (informatif) ==="
    cc --version 2>&1 | head -2 || true
    ld.lld --version 2>&1 | head -1 || true
    echo "--- libarchive : 32 bits (/usr/lib) vs 64 bits (/usr/lib64) ---"
    ls -l /usr/lib/libarchive* 2>&1 | head -5 || true
    ls -l /usr/lib64/libarchive* 2>&1 | head -5 || true
    file /usr/lib/libarchive.so /usr/lib64/libarchive.so 2>&1 | head -5 || true
    echo "--- ce que pkg-config dicte à configure ---"
    pkg-config --libs libarchive 2>&1 || true
    pkg-config --libs composefs 2>&1 || true
    echo "--- lien minimal reprenant la queue de la ligne fautive ---"
    printf 'int main(void){return 0;}\n' > /tmp/alba-probe.c
    if cc -m64 -o /tmp/alba-probe /tmp/alba-probe.c \
           -L/usr/lib -larchive -lcomposefs 2>&1 | head -10; then
        echo "PROBE: lien 64 bits avec -L/usr/lib OK"
    else
        echo "PROBE: lien 64 bits avec -L/usr/lib ECHOUE"
    fi
    echo "=== fin diagnostic ==="
}
diagnostic_toolchain || true

printf '[alba-local]\nname=Alba local bricks\nbaseurl=file://%s\nenabled=1\ngpgcheck=0\npriority=1\n' \
    "$RPMS" > /etc/yum.repos.d/alba-local.repo
createrepo_c --quiet "$RPMS"

# --- bootupd : générer le tarball vendor patché (Source1) -------------------
# bootupd dépend d'openssl-sys 0.9.x, dont le script de build REFUSE OpenSSL 4.0
# (qu'OMV embarque) : il borne la version supportée à 0x4_00_00_00_0. On vendore
# les crates, on élargit la borne, et on recalcule le .cargo-checksum.json du
# crate modifié (sans quoi cargo refuse le vendor). Build ensuite hors ligne.
prepare_bootupd_vendor() {
    local ver src tmp
    ver=$(awk '/^Version:/ {print $2}' "$WORK/bootupd/bootupd.spec")
    src="$TOPDIR/SOURCES/bootupd-$ver-vendor.tar.gz"
    # déjà fourni avec la brique (copié dans SOURCES par build_brick) : rien à faire
    if [ -f "$src" ]; then
        echo "bootupd : tarball vendor déjà présent, pas de cargo vendor"
        return 0
    fi

    echo "=== bootupd : cargo vendor + patch openssl-sys ==="
    tmp=$(mktemp -d)
    tar -C "$tmp" -xzf "$WORK/bootupd/bootupd-$ver.tar.gz"
    (
        cd "$tmp/bootupd-$ver"
        cargo vendor vendor >/dev/null

        local main_rs="vendor/openssl-sys/build/main.rs"
        [ -f "$main_rs" ] || { echo "ERREUR: $main_rs absent du vendor"; exit 1; }
        if grep -q '0x4_00_00_00_0' "$main_rs"; then
            sed -i 's/0x4_00_00_00_0/0x5_00_00_00_0/g' "$main_rs"
            python3 - "vendor/openssl-sys" <<'PY'
import hashlib, json, pathlib, sys
crate = pathlib.Path(sys.argv[1])
cs = crate / ".cargo-checksum.json"
data = json.loads(cs.read_text())
for name in data.get("files", {}):
    f = crate / name
    if f.is_file():
        data["files"][name] = hashlib.sha256(f.read_bytes()).hexdigest()
cs.write_text(json.dumps(data))
PY
            echo "openssl-sys : borne de version élargie (OpenSSL 4.x accepté)"
        else
            echo "ATTENTION: borne 0x4_00_00_00_0 introuvable dans openssl-sys ;"
            echo "           soit le crate a été corrigé en amont, soit le fix a bougé."
        fi
        # --no-xattrs en écriture aussi : le tarball doit rester restaurable
        # sur un système sans xattrs utilisateur (piège composefs de clairdelune).
        tar --no-xattrs -czf "$src" vendor
    )
    rm -rf "$tmp"
}

build_brick() {
    local name="$1" dir="$WORK/$1" spec f
    spec="$dir/$name.spec"
    [ -f "$spec" ] || { echo "ERREUR: $spec introuvable"; exit 1; }

    echo "=== brique : $name ==="
    for f in "$dir"/*; do
        [ "$f" = "$spec" ] && continue
        [ -f "$f" ] && cp -f "$f" "$TOPDIR/SOURCES/"
    done
    if [ "$name" = bootupd ]; then prepare_bootupd_vendor; fi

    # les briques déjà construites sont visibles via le dépôt local
    createrepo_c --quiet --update "$RPMS"
    dnf -y --refresh builddep "$spec"
    rpmbuild -ba --define "_topdir $TOPDIR" "$spec"

    find "$TOPDIR/RPMS" -name '*.rpm' -exec cp -f {} "$RPMS/" \;
    createrepo_c --quiet "$RPMS"
}

for brick in $BRICKS; do
    build_brick "$brick"
done

echo "=== RPM produits ==="
ls -1 "$RPMS"/*.rpm | sed 's#.*/##'
