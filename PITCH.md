# Alba — an atomic KDE edition of OpenMandriva (working PoC)

*Alba Longa, the mother city of Rome — an image-based edition built on ROME.*

## What it is

Alba is a proposal for an **atomic/immutable KDE variant of OpenMandriva**, in the
family of Fedora Kinoite / Universal Blue Aurora / openSUSE Kalpa. It is **not a
fork**: it assembles a bootable **bootc** container image from stock ROME
packages, exactly the way Universal Blue derives its images from Fedora.

Key properties for users:

- **Atomic upgrades and rollbacks** — the OS is a container image; `bootc
  switch`/`upgrade` stages the new image, a reboot activates it, `bootc
  rollback` returns to the previous deployment. A broken update can no longer
  brick a machine. This directly de-risks ROME's rolling release model.
- **Read-only root** (composefs + fs-verity), mutable `/etc` and `/var`,
  `/home → /var/home` (Kinoite convention).
- **Apps via Flatpak, toolboxes via distrobox/podman** — the base stays small;
  the desktop is a layered image (`FROM alba-base` + Plasma package sets).
- **Image-based customisation** — site or user variants are a Containerfile,
  built and shipped through any OCI registry. No client-side package layering
  needed (no rpm-ostree; this is bootc "image mode", the direction Fedora/CentOS
  are converging on).

## Status: the PoC works, end to end

Everything below has been **built and demonstrated locally** (no infra changes,
nothing published), on stock ROME/cooker package repositories:

1. **Six RPM bricks built** with the native OMV toolchain (clang):
   `composefs`, `ostree` rebuilt with the composefs backend, `bootc` (1.16.2),
   `bootupd` (0.2.34), `skopeo` bump, and a from-source `shim` 16.1 (unsigned).
2. **A bootc base image** (`Containerfile.base` FROM `openmandriva/cooker`,
   ~990 MB uncompressed, 221 packages) that passes `bootc container lint`
   **with zero warnings** (sysusers/tmpfiles manifests generated at build;
   rpmdb relocated to `/usr/lib/sysimage/rpm`; locales trimmed to en/fr).
3. **`bootc install to-disk` completes**: GPT (BIOS boot + ESP + root),
   ext4 + fs-verity, ostree deploy, bootloader installed by bootupd.
4. **It boots** — both **BIOS/SeaBIOS and UEFI/OVMF** (fallback
   `\EFI\BOOT\BOOTX64.EFI`) — to `graphical.target`, root on composefs.
5. **Atomic upgrade/rollback demonstrated** (twice, including once after a live
   grub rolling regression): boot v1 → `bootc switch` to v2 (pulled from a
   registry; **only the changed layers transfer** — kilobytes for a
   one-file change, thanks to OSTree/OCI deduplication) → reboot → v2 →
   `bootc rollback` → reboot → v1. `systemctl is-system-running` → `running`.
6. **A Plasma 6 layer** (`FROM alba-base` + plasma packages, SDDM, autologin)
   boots to the SDDM greeter; exported as a 1.5 GiB qcow2 that runs in GNOME
   Boxes / QEMU. (Greeter widgets need a GPU-capable VM — software rendering of
   the QML greeter is the usual VM artefact, not an Alba bug.)

## What OMV was missing (now packaged, ready to upstream)

| Package | State | Notes for upstreaming |
|---|---|---|
| `composefs` 1.0.8 | new package | clang fix: `-Wno-error=incompatible-pointer-types-discards-qualifiers` |
| `ostree` 2026.2 | bump + `--with-composefs` | current spec says "synchronized with Fedora" → needs maintainer buy-in (bero) |
| `bootc` 1.16.2 | new package (Rust) | cargo offline + vendored crates (OMV has no cargo-rpm-macros) |
| `bootupd` 0.2.34 | new package (Rust) | two patches: openssl-sys accepts OpenSSL 4.x (as Fedora vendors it); `SHIM` const → `grub.efi` while OMV has no shim |
| `skopeo` 1.17.0 | version bump | needed by `bootc install`; Go build, vendored |
| `shim` 16.1 | new package, from-source | unsigned PoC build (self-generated vendor cert); needed for Secure Boot and to drop the bootupd SHIM patch. Build fixes: `LD=ld.bfd` (lld rejects the EFI link) and `FORMAT='--output-target efi-app-x86_64'` (binutils ≥ 2.46 applies `--target` to the input too) |

## Distro-level coordination points

These are the genuinely distro-facing questions, where a TC opinion matters:

- **GRUB and BLS entries.** bootupd's static grub config relies on `blscfg`,
  which OMV's grub has only intermittently (2.14 via `blsuki`, gone in 2.12 —
  observed live as a rolling regression). Alba currently sidesteps grub
  versions entirely: a generator writes explicit menuentries from the BLS
  entries on every deployment change (systemd drop-in on
  `ostree-finalize-staged`). Longer term, OMV could patch grub2 to provide
  `blscfg` stably, or adopt the generator.
- **Filesystem conventions.** `/home → /var/home`, `/root → /var/roothome`,
  `/opt → /var/opt` in the image (bootc/Kinoite convention).
- **rpmdb location.** Alba moves it to `/usr/lib/sysimage/rpm` (Fedora bootc
  convention; the package set is immutable at runtime by design).
- **Secure Boot.** OMV ships no shim; nothing signed. Fine for a PoC, needs a
  plan (shim review process) if Alba becomes official.
- **Kernel config.** Stock OMV kernel works as-is (EROFS, overlayfs,
  fs-verity all enabled). `CONFIG_OVERLAY_FS_METACOPY` worth pinning in the
  fragments.
- **Application delivery.** An atomic image ships applications through Flatpak,
  so "which remote do we preconfigure, and on whose authority" becomes a distro
  decision. Proposal: Flathub restricted to its `verified_floss` subset by
  default (about 2000 of 3285 applications, dropping third-party packaging and
  non-free licences), plus a small OpenMandriva-specific repository served as a
  signed static OSTree tree by the existing mirror network. Rationale, figures
  and the "build our own Clang runtime?" question: [FLATPAK.md](FLATPAK.md).
- **Base-system weight.** ~170 MB of every OMV install is `lib64llvm` +
  `lib64z3`, dragged in by `libomp` — which `lib64crypto3` (OpenSSL), libcrypt
  and rpmbuild link against. Nothing an image can drop; only packaging can
  (split libomp, or stop linking crypto against it). Worth a look independently
  of Alba: it inflates containers and minimal installs alike.

## Why this is cheap to adopt

- Zero impact on existing editions: it is additive — a handful of packages plus
  a Containerfile in CI. The "distro" layer (image assembly, Flatpak defaults)
  is deliberately thin; the heavy lifting is upstream bootc/ostree.
- The rolling-release risk that makes people hesitant about ROME is exactly
  what atomicity mitigates: every update is transactional and reversible.
- Fedora, CentOS, Ubuntu Core and Universal Blue all point the same way:
  image-based OS delivery. OMV can have this with ~6 packages and one repo.

## Reproducing the demo

On any x86_64 machine with rootless podman + KVM:

```
# 1. build the RPM bricks in an OMV cooker container   (build-*.sh)
# 2. build the base image (lint-clean)                 (bash build-base.sh)
# 3. full scripted demo: v1 → switch v2 → rollback     (bash tools/alba-demo-cycle.sh [--uefi])
#    or step by step:
bash tools/alba-install.sh <image>   # → output/alba.raw, boots BIOS or UEFI as-is
bootc switch <registry>/alba:v2      # stage the new image
reboot                               # boot v2, previous kept for rollback
bootc rollback && reboot             # back to v1
# Plasma desktop image + qcow2 export: bash tools/alba-plasma-image.sh
```

A ready-made Plasma qcow2 exists for GNOME Boxes / virt-manager (BIOS mode,
Secure Boot off).

## Asks

1. **Feedback on the approach** (bootc vs status quo; naming; scope: KDE first).
2. **ABF access** to build the bricks properly and iterate towards the main
   repos (currently built locally in cooker containers).
3. **A decision path for the coordination points above** — none of them blocks
   a community preview, all of them matter for an official edition.
