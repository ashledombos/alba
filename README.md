# Alba — variante KDE atomique/immutable d'OpenMandriva

POC **fonctionnel** d'une base **bootc** pour OpenMandriva ROME (x86_64),
modèle Kinoite/Aurora : boot + upgrade + rollback atomiques prouvés en VM.
Présentation et argumentaire : `PITCH.md`. Plan d'origine :
`~/.claude/plans/j-ai-un-projet-j-aimerais-crystalline-rabin.md`.

Tout se construit **en local** (conteneurs podman rootless sur un hôte x86_64
avec KVM) : les RPM dans un conteneur `openmandriva/cooker` outillé
(`localhost/omv-builder`), l'image et le disque via podman + un wrapper root.
ABF ne servira que pour upstreamer, une fois le projet accepté.

## Les 6 briques RPM (ordre de build imposé)

| # | Brique | Rôle | Particularités |
|---|--------|------|----------------|
| 1 | `composefs/` 1.0.8 | racine immuable (EROFS+overlay) | fix Clang `-Wno-error=incompatible-pointer-types-…` |
| 2 | `ostree/` 2026.2 | dépôt/déploiements OS | rebuild `--with-composefs` (exige lib64composefs-devel) ; spec OMV « synced with Fedora » → à coordonner |
| 3 | `bootc/` 1.16.2 | gestion d'OS en image OCI | Rust, cargo offline + crates vendored ; module dracut 51bootc |
| 4 | `bootupd/` 0.2.34 | installation/màj bootloader | 2 patches : openssl-sys accepte OpenSSL 4.x ; `SHIM = "grub.efi"` (OMV n'a pas de shim) |
| 5 | `skopeo/` 1.17.0 | import d'images (bootc install) | Go `-mod=vendor` |
| 6 | `shim/` 16.1 | 1er étage UEFI (Secure Boot, plus tard) | from-source non signé ; binutils ≥ 2.46 : `FORMAT='--output-target efi-app-x86_64'` + `LD=ld.bfd` |

Build : `build-<brique>.sh` dans le conteneur omv-builder, RPM déposés dans
`rpms/` qui sert de dépôt local (`createrepo_c`, `file:///rpms`) au build
d'image. Piège OMV récurrent : Clang strict, `lib64atomic-devel`, `make`/`gcc`
non tirés par rpm-build.

## Images (Containerfiles)

- `base/Containerfile.base` — la base bootc minimale (sans bureau), **mono-stage
  `FROM openmandriva/cooker`** (un `--installroot` casserait les scriptlets
  sysusers de systemd). Contient : noyau+initramfs dans
  `/usr/lib/modules/$kver`, prepare-root composefs, payload bootupd
  (grub2-static BLS **+ fallback UEFI `EFI/BOOT/BOOTX64.EFI`**), menu grub
  généré **indépendant de la version de grub** (`gen-grub-menu.sh`, déclenché
  par drop-in sur `ostree-finalize-staged` + service de rattrapage au boot),
  manifestes sysusers/tmpfiles générés (`gen-image-manifests.sh`, lint = 0
  warning), NetworkManager (networkd = conflit RPM avec plasma-nm), slim
  locales en/fr + nodocs. `/home→var/home` etc. (convention Kinoite).
- `alba/Containerfile.alba` — couche Plasma 6 (`FROM alba-base` +
  task-plasma-minimal, SDDM, compte `alba`/`alba`, autologin).
- `demo/Containerfile.demo` — surcouche de démo upgrade/rollback (sshd, clé
  baked dans /usr, marqueur `/etc/alba-version`, registry insecure).

## Pipeline d'install et de test (sur l'hôte de build)

```
bash build-base.sh                      # image localhost/alba-base (+ lint)
bash tools/alba-install.sh [IMAGE]      # → output/alba.raw bootable :
                                        #   podman save → sudo alba-imgbuild
                                        #   (bootc install to-disk --via-loopback)
                                        #   + regen OFFLINE du grub.cfg du 1er boot
                                        #   (debugfs ; grub 2.12 OMV n'a pas blscfg)
bash run-c2.sh                          # démo complète v1→switch v2→rollback
```

Boot VM : QEMU/KVM rootless (conteneur `localhost/alba-qemu`), BIOS/SeaBIOS
direct, ou UEFI/OVMF (fallback BOOTX64.EFI ; VARS neuf OK). Export :
qcow2 compressé via `qemu-img convert -c` (GNOME Boxes : BIOS, Secure Boot off).

## Pièges connus (résolus, ne pas re-payer)

- **grub rolling** : 2.14 a `blscfg` (via blsuki), 2.12 non → ne JAMAIS dépendre
  de blscfg ; le menu explicite regénéré à chaque déploiement est la parade.
- `podman build --no-cache` pour la base (métadonnées dnf périmées en cache).
- Volumes : `--security-opt label=disable` quand on monte tout `~/alba`
  (relabel `:z` échoue sur `output/alba.raw` root).
- `bootc install` exige podman/netavark/skopeo/dosfstools DANS l'image.
- mtools OMV : gconv CP850 absent → manipuler l'ESP depuis un conteneur Fedora.
- `ssh` dans un heredoc consomme stdin → `ssh -n`.
- Sources en double (`~/dev/alba` local ↔ `~/alba` hôte de build) : resync
  avant tout rebuild.
