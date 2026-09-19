# Alba — an atomic/immutable KDE variant of OpenMandriva

⚠️ **Status: personal, unofficial exploration.** Alba is a solo effort by
an OpenMandriva contributor, meant to inform a discussion with the
Technical Committee. Neither the name "Alba" nor this repository have
been endorsed by the TC. Nothing here commits the OpenMandriva project.

Working **PoC** of a **bootc** base for OpenMandriva ROME (x86_64), Kinoite/Aurora
model: boot + upgrade + rollback atomicity proven in a VM. Pitch and rationale:
`PITCH.md`. Original plan: `~/.claude/plans/j-ai-un-projet-j-aimerais-crystalline-rabin.md`.

Everything builds **locally** (rootless podman containers on an x86_64 host with
KVM): the RPMs in a tooled `openmandriva/cooker` container (`localhost/omv-builder`),
the image and disk via podman + a root wrapper. ABF will only be used to upstream,
once the project is accepted.

## The 6 RPM bricks (build order enforced)

| # | Brick | Role | Notes |
|---|-------|------|-------|
| 1 | `composefs/` 1.0.8 | immutable root (EROFS+overlay) | Clang fix `-Wno-error=incompatible-pointer-types-…` |
| 2 | `ostree/` 2026.2 | OS repo/deployments | rebuilt `--with-composefs` (needs lib64composefs-devel); OMV spec is "synced with Fedora" → to coordinate |
| 3 | `bootc/` 1.16.2 | OS management via OCI image | Rust, offline cargo + vendored crates; dracut module 51bootc |
| 4 | `bootupd/` 0.2.34 | bootloader install/update | 2 patches: openssl-sys accepts OpenSSL 4.x; `SHIM = "grub.efi"` (OMV has no shim) |
| 5 | `skopeo/` 1.17.0 | image import (bootc install) | Go `-mod=vendor` |
| 6 | `shim/` 16.1 | 1st-stage UEFI (Secure Boot, later) | from-source, unsigned; binutils ≥ 2.46: `FORMAT='--output-target efi-app-x86_64'` + `LD=ld.bfd` |

Build: `build-<brick>.sh` in the omv-builder container, RPMs dropped in `rpms/`,
which serves as a local repo (`createrepo_c`, `file:///rpms`) for the image build.
Recurring OMV pitfall: strict Clang, `lib64atomic-devel`, `make`/`gcc` not pulled
in by rpm-build.

## Images (Containerfiles)

- `base/Containerfile.base` — the minimal bootc base (no desktop), **mono-stage
  `FROM openmandriva/cooker`** (an `--installroot` would break systemd's sysusers
  scriptlets). Contains: kernel+initramfs in `/usr/lib/modules/$kver`, composefs
  prepare-root, bootupd payload (grub2-static BLS **+ UEFI fallback
  `EFI/BOOT/BOOTX64.EFI`**), a grub menu generator **independent of the grub
  version** (`gen-grub-menu.sh`, triggered by a drop-in on `ostree-finalize-staged`
  plus a boot-time catch-up service), generated sysusers/tmpfiles manifests
  (`gen-image-manifests.sh`, 0-warning lint), NetworkManager (networkd conflicts
  at the RPM level with plasma-nm), slim en/fr locales + nodocs. `/home→var/home`
  etc. (Kinoite convention).
- `alba/Containerfile.alba` — Plasma 6 layer (`FROM alba-base` + task-plasma-minimal,
  SDDM, `alba`/`alba` account, autologin).
- `demo/Containerfile.demo` — upgrade/rollback demo overlay (sshd, key baked into
  /usr, `/etc/alba-version` marker, insecure registry).

## Install and test pipeline (on the build host)

```
bash build-base.sh                      # localhost/alba-base image (+ lint)
bash tools/alba-install.sh [IMAGE]      # → bootable output/alba.raw:
                                        #   podman save → sudo alba-imgbuild
                                        #   (bootc install to-disk --via-loopback)
                                        #   + OFFLINE regen of the 1st-boot grub.cfg
                                        #   (debugfs; OMV grub 2.12 has no blscfg)
bash run-c2.sh                          # full demo v1→switch v2→rollback
```

VM boot: rootless QEMU/KVM (`localhost/alba-qemu` container), direct BIOS/SeaBIOS,
or UEFI/OVMF (BOOTX64.EFI fallback; works with fresh VARS). Export: compressed
qcow2 via `qemu-img convert -c` (GNOME Boxes: BIOS, Secure Boot off).

## Continuous integration (GitHub Actions)

`.github/workflows/build.yml` — on push to `main` and on manual dispatch: builds
the 6 RPM bricks (`tools/ci-build-rpms.sh`, in an `openmandriva/cooker` container),
then `base/Containerfile.base`, then a **blocking** `bootc container lint` gate,
then pushes `ghcr.io/<account>/alba-base` with a dated tag (`YYYYMMDD-<sha>`) and
`latest`. Authenticated with the workflow's `GITHUB_TOKEN` (`permissions:
packages: write`).

The runner has **no guaranteed KVM**: no VM boot in CI. The lint is therefore the
only automatic gate; boot, upgrade and rollback are still checked by hand on a
KVM-capable host (`tools/alba-install.sh`, `tools/alba-demo-cycle.sh`). Nothing is
cached between runs: cooker is rolling, and that's exactly the kind of regression
(cf. grub 2.14 → 2.12) this is meant to catch.

`tools/ci-build-rpms.sh` is the "throwaway runner" version of the build host's
`build-<brick>.sh` scripts: no sudo wrapper, no systemd slice, no pre-built
`omv-builder` image (the cooker container bootstraps its own tooling). It also
generates bootupd's vendor tarball (`cargo vendor` + widening the openssl-sys
bound for OpenSSL 4.x + recomputed `.cargo-checksum.json`), which is not versioned.

## Known pitfalls (resolved, don't re-pay them)

- **Rolling grub**: 2.14 has `blscfg` (via blsuki), 2.12 doesn't → never depend on
  blscfg; a menu regenerated explicitly on every deployment is the fix.
- `podman build --no-cache` for the base (stale cached dnf metadata otherwise).
- Volumes: `--security-opt label=disable` when mounting all of `~/alba` (`:z`
  relabeling fails on the root-owned `output/alba.raw`).
- `bootc install` requires podman/netavark/skopeo/dosfstools inside the image.
- OMV mtools: missing CP850 gconv → manipulate the ESP from a Fedora container.
- `ssh` inside a heredoc consumes stdin → use `ssh -n`.
- Duplicated sources (`~/dev/alba` local ↔ `~/alba` on the build host): resync
  before every rebuild.
