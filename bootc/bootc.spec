# Alba — brique #3 : bootc
# Adapté de la spec Fedora aux conventions OMV, SANS les macros Fedora absentes
# (cargo-rpm-macros / rust-toolset) : build via `cargo build` offline + crates
# vendored (Source1) + `make install` (bootc fournit un Makefile).
#
# Fournit /usr/bin/bootc, le module dracut 51bootc (référencé par notre
# 10-bootc-base.conf), les générateurs systemd et les hooks ostree.
#
# NB à valider au 1er build ABF :
#  - extraction des sources .tar.zstd par rpm4 OMV (zstd natif en rpm >= 4.19) ;
#  - build offline (nœuds ABF sans réseau) → d'où le tarball vendor Source1 ;
#  - présence de go-md2man dans les dépôts (sinon désactiver les manpages).

# Le Makefile de bootc lie la cible `install` à `manpages` → go-md2man requis
# de toute façon. go-md2man est packagé dans OMV, on active donc les manpages.
%bcond_without manpages

# POC : tolérer les fichiers non listés (complétions elvish/powershell, etc.)
%global _unpackaged_files_terminate_build 0

Summary:	Bootable container system
Name:		bootc
Version:	1.16.2
Release:	1
License:	Apache-2.0 AND MIT AND BSD-3-Clause
URL:		https://github.com/bootc-dev/bootc
Source0:	%{url}/releases/download/v%{version}/bootc-%{version}.tar.zstd
Source1:	%{url}/releases/download/v%{version}/bootc-%{version}-vendor.tar.zstd

BuildRequires:	rust
BuildRequires:	cargo
BuildRequires:	make
BuildRequires:	pkgconfig(ostree-1)
BuildRequires:	pkgconfig(openssl)
BuildRequires:	pkgconfig(libzstd)
BuildRequires:	systemd
BuildRequires:	systemd-macros
%if %{with manpages}
BuildRequires:	go-md2man
%endif

Requires:	ostree
Requires:	podman
# skopeo : requis par bootc au runtime (pull d'images) mais PAS packagé dans OMV.
# Différé pour le POC (à sourcer/builder avant la démo `bootc upgrade`).
# Requires:	skopeo

%description
bootc permet de gérer un système Linux transactionnel dont l'état provient
d'une image conteneur (OCI/Docker) bootable. C'est le socle du modèle
« image mode » (Fedora bootc, Universal Blue/Aurora) : mises à jour et
rollback atomiques via `bootc upgrade` / `bootc switch` / `bootc rollback`.

%prep
# -a1 : déballe le tarball vendored (crates) dans ./vendor
%autosetup -n %{name}-%{version} -p1 -a1
mkdir -p .cargo
# bootc fournit sa propre vendor-config (gère aussi ses deps git) : l'utiliser telle quelle.
if [ -f .cargo/vendor-config.toml ]; then
    cp -f .cargo/vendor-config.toml .cargo/config.toml
else
    cat > .cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"
[source.vendored-sources]
directory = "vendor"
EOF
fi

%build
export CARGO_HOME="%{_builddir}/%{name}-%{version}/.cargo"
export CARGO_NET_OFFLINE=true
# LTO neutralisé : le profil release de bootc compile en « -C lto=thin », et le
# rustc de cooker tombe en erreur interne dans le codegen LTO
#   rustc-LLVM ERROR: expected function definition ..._rust_alloc to have an
#   associated value info
# dès le premier crate compilé (xtask, cible « manpages »). Sans LTO, la brique
# se construit entière. Régression de toolchain, à retirer quand cooker l'aura
# corrigée ; le coût est un binaire un peu plus gros, sans effet sur le POC.
export CARGO_PROFILE_RELEASE_LTO=false
%if %{with manpages}
make manpages
%endif
cargo build --release --offline --bins

%install
export CARGO_HOME="%{_builddir}/%{name}-%{version}/.cargo"
export CARGO_NET_OFFLINE=true
# Même neutralisation qu'en %build : chaque section tourne dans un shell neuf,
# et make install recompile xtask (cible manpages) avec le profil release.
export CARGO_PROFILE_RELEASE_LTO=false
# Le Makefile de bootc installe binaire + unités + hooks (DESTDIR/prefix standard)
%make_install INSTALL="install -p -c"
make install-ostree-hooks DESTDIR=%{buildroot}

%files
%license LICENSE-MIT LICENSE-APACHE
%doc README.md
%{_bindir}/bootc
%{_bindir}/system-reinstall-bootc
%{_prefix}/lib/bootc/
%{_prefix}/lib/systemd/system-generators/*
%{_prefix}/lib/systemd/system/bootc-*
%{_prefix}/lib/dracut/modules.d/51bootc/
%{_libexecdir}/libostree/ext/*
%{_datadir}/bash-completion/completions/bootc
%{_datadir}/fish/vendor_completions.d/bootc.fish
%{_datadir}/zsh/site-functions/_bootc
%{_docdir}/bootc/baseimage/
%if %{with manpages}
%{_mandir}/man*/bootc*
%{_mandir}/man*/system-reinstall-bootc*
%endif
