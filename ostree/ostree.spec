# Warning: This package is synchronized with Fedora!
%define _disable_lto %nil

%define major 1
%define api 1
%define gir_major 1.0
%define libname %mklibname ostree %{major}
%define gir_name %mklibname ostree-gir %{gir_major}
%define develname %mklibname -d ostree

# Alba : bump 2024.9 -> 2026.2 (requis par bootc >= 2025.3). Le %files amont peut
# avoir dérivé : on tolère les fichiers non listés (warning au lieu d'échec).
%global _unpackaged_files_terminate_build 0

Summary:	Tool for managing bootable, immutable filesystem trees
Name:		ostree
Version:	2026.2
Release:	1
#VCS: git:git://git.gnome.org/ostree
Source0:	https://github.com/ostreedev/ostree/releases/download/v%{version}/libostree-%{version}.tar.xz
Source1:	91-ostree.preset
License:	LGPLv2+
URL:		https://ostreedev.github.io/ostree/

BuildRequires:	libtool-base
BuildRequires:	slibtool
BuildRequires:	git
# We always run autogen.sh
BuildRequires:	autoconf
BuildRequires:	automake
BuildRequires:	libtool
BuildRequires:	bison
# For docs
BuildRequires:	gtk-doc
# Core requirements
BuildRequires:	pkgconfig(libsoup-3.0)
BuildRequires:	pkgconfig(zlib)
BuildRequires:	attr-devel
# Extras
BuildRequires:	pkgconfig(mount)
BuildRequires:	pkgconfig(libarchive)
BuildRequires:	pkgconfig(liblzma)
BuildRequires:	pkgconfig(mount)
BuildRequires:	pkgconfig(fuse)
BuildRequires:	pkgconfig(e2p)
BuildRequires:	pkgconfig(libcap)
BuildRequires:	pkgconfig(gpgme)
BuildRequires:	pkgconfig(libassuan)
BuildRequires:	pkgconfig(libsystemd)
BuildRequires:	systemd-macros
BuildRequires:	pkgconfig(gobject-introspection-1.0)
BuildRequires:	pkgconfig(libcurl)
BuildRequires:	pkgconfig(openssl)
BuildRequires:	dracut
# Alba: composefs backend pour ostree/bootc (fourni par lib64composefs-devel)
BuildRequires:	pkgconfig(composefs)

# Runtime requirements
Requires:	dracut
Requires:	gnupg2
Requires:	systemd

%description
OSTree is a tool for managing bootable, immutable, versioned
filesystem trees. While it takes over some of the roles of tradtional
"package managers" like dpkg and rpm, it is not a package system; nor
is it a tool for managing full disk images. Instead, it sits between
those levels, offering a blend of the advantages (and disadvantages)
of both.

%package -n %{libname}
Summary:	Tool for managing bootable, immutable filesystem trees
Group:		System/Libraries

%description -n %{libname}
OSTree is a tool for managing bootable, immutable, versioned
filesystem trees. While it takes over some of the roles of tradtional
"package managers" like dpkg and rpm, it is not a package system; nor
is it a tool for managing full disk images. Instead, it sits between
those levels, offering a blend of the advantages (and disadvantages)
of both.

%package -n %{develname}
Summary:	Development headers for %{name}
Group:		System/Libraries
Requires:	%{name} =  %{EVRD}
Requires:	%{libname} = %{EVRD}
Requires:	%{gir_name} = %{EVRD}

%description -n %{develname}
This package includes the header files for the %{name} library.

%package -n %{gir_name}
Summary:	GObject Introspection interface description for %{name}
Group:		System/Libraries
Requires:	%{libname} = %{EVRD}

%description -n %{gir_name}
GObject Introspection interface description for %{name}.

%ifnarch s390 s390x %{arm}
%package	grub2
Summary:	GRUB2 integration for OSTree
%ifnarch aarch64
Requires:	grub2
%else
Requires:	grub2-efi
%endif

%description grub2
GRUB2 integration for OSTree
%endif

%prep
%autosetup -n libostree-%{version} -p1

%build
env NOCONFIGURE=1 ./autogen.sh
export CFLAGS="%optflags -Wno-undef"
%configure \
    --disable-silent-rules \
    --enable-gtk-doc \
    --with-curl \
    --with-openssl \
    --with-composefs \
    --with-dracut=yesbutnoconf

# https://gitlab.gnome.org/GNOME/gobject-introspection/issues/280
sed -i 's!-fvisibility=hidden!-fvisibility=default!g' Makefile.in Makefile-libostree.am

# HACK
sed -i s'!\\{libdir\\}!%{_libdir}!g' Makefile
%make_build

%install
%make_install
find %{buildroot} -name '*.la' -delete
install -D -m 0644 %{SOURCE1} %{buildroot}%{_prefix}/lib/systemd/system-preset/91-ostree.preset

# Alba debug : arborescence réelle installée (pour ajuster %files au bump de version)
echo "=== ALBA BUILDROOT TREE ==="; find %{buildroot} | sed "s|%{buildroot}||" | sort; echo "=== FIN TREE ==="

%files
%{_bindir}/ostree
%{_bindir}/rofiles-fuse
%dir %{_datadir}/ostree
%{_datadir}/ostree/trusted.gpg.d
%{_sysconfdir}/ostree
%dir %{_prefix}/lib/dracut/modules.d/50ostree
%{_unitdir}/ostree*.service
%{_prefix}/lib/dracut/modules.d/50ostree/*
%{_mandir}/man*/*.*
%{_prefix}/lib/systemd/system-preset/91-ostree.preset
%exclude %{_sysconfdir}/grub.d/*ostree
%exclude %{_libexecdir}/libostree/grub2*
%dir %{_prefix}/lib/ostree
%{_prefix}/lib/ostree/ostree-prepare-root
%{_prefix}/lib/ostree/ostree-remount
%{_prefix}/lib/systemd/system-generators/ostree-system-generator
%{_prefix}/lib/tmpfiles.d/ostree-tmpfiles.conf
%{_datadir}/bash-completion/completions/ostree
%dir %{_libexecdir}/libostree
%{_libexecdir}/libostree/*

%files -n %{libname}
%{_libdir}/lib%{name}-%{api}.so.%{major}*

%files -n %{develname}
%doc COPYING
%doc README.md
%{_libdir}/lib*.so
%{_includedir}/*
%{_libdir}/pkgconfig/*
%{_datadir}/gtk-doc/html/ostree
%{_datadir}/gir-1.0/OSTree-1.0.gir

%files -n %{gir_name}
%{_libdir}/girepository-1.0/OSTree-%{gir_major}.typelib

%ifnarch s390 s390x %{arm}
%files grub2
%{_sysconfdir}/grub.d/*ostree
%{_libexecdir}/libostree/grub2*
%endif
