# Alba — brique #4 : bootupd
# Gestion atomique du bootloader pour bootc/ostree. Fournit /usr/bin/bootupctl,
# le daemon, et le payload **grub2-static** (/usr/lib/bootupd/grub2-static, avec
# 10_blscfg.cfg) : la config GRUB2 statique qui active blscfg et lit
# /boot/loader/entries — ce qui fait booter la base OMV en mode BLS.
#
# Rust (Makefile, cible `install-all`). Build OFFLINE avec crates vendored
# PATCHÉS : openssl-sys 0.9.112 rejette OpenSSL 4.0 (que porte OMV) ; on a
# élargi sa borne de version (4.x traité comme 3.x) dans le tarball vendor
# (Source1), checksum .cargo-checksum.json ajusté en conséquence.

%global _unpackaged_files_terminate_build 0

Summary:	Bootloader updates and static config for bootc/ostree systems
Name:		bootupd
Version:	0.2.34
Release:	1
License:	Apache-2.0
URL:		https://github.com/coreos/bootupd
Source0:	%{url}/archive/v%{version}/%{name}-%{version}.tar.gz
# Généré par `cargo vendor` + patch openssl-sys pour OpenSSL 4.0 (cf. en-tête)
Source1:	%{name}-%{version}-vendor.tar.gz

BuildRequires:	rust
BuildRequires:	cargo
BuildRequires:	make
BuildRequires:	pkgconfig(openssl)
BuildRequires:	systemd
BuildRequires:	systemd-macros

Requires:	grub2

%description
bootupd gère les mises à jour du firmware de boot sur les systèmes
transactionnels bootc/ostree, et fournit un payload GRUB2 statique (config BLS)
déployé dans /usr/lib/bootupd.

%prep
%autosetup -n %{name}-%{version} -p1
# Alba (POC) : OMV n'a pas de shim. On fait de grub.efi (RPM-owned, grub2-efi)
# l'entrée EFI directe attendue par bootupd, au lieu de shimx64.efi. OVMF SB off.
sed -i 's/const SHIM: &str = "shimx64.efi"/const SHIM: \&str = "grub.efi"/' src/efi.rs
grep -n 'const SHIM' src/efi.rs
# --no-xattrs : le tarball vendor a été créé sur composefs (xattrs), non restaurables ici
tar --no-xattrs -xzf %{SOURCE1}
mkdir -p .cargo
cat > .cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"
[source.vendored-sources]
directory = "vendor"
EOF

%build
export CARGO_NET_OFFLINE=true
cargo build --release --offline

%install
export CARGO_NET_OFFLINE=true
# install-all = bin + grub2-static + unité systemd (cf. Makefile amont)
make install-all DESTDIR=%{buildroot} PREFIX=%{_prefix} LIBEXECDIR=%{_libexecdir} PROFILE=release INSTALL="install -p -c"

%files
%{_bindir}/bootupctl
%{_libexecdir}/bootupd
%{_prefix}/lib/bootupd/
%{_unitdir}/bootloader-update.service
