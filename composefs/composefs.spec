# Alba — brique #1 : composefs
# Adapté de la spec Fedora (src.fedoraproject.org/rpms/composefs) aux
# conventions OpenMandriva (%%mklibname / library policy, champs tabulés).
# Fournit lib64composefs1 + lib64composefs-devel (requis pour rebâtir
# ostree avec --with-composefs) et les outils mkcomposefs / mount.composefs.

# Pages de man désactivées par défaut (évite la dépendance go-md2man).
# Passer --with man si go-md2man est disponible dans les dépôts.
%bcond_with man

%define major		1
%define libname		%mklibname composefs %{major}
%define develname	%mklibname -d composefs

# OMV compile en Clang : composefs 1.0.8 met -Werror=incompatible-pointer-types
# et Clang traite en erreur un memchr() qui perd le const (mkcomposefs.c).
# On relâche uniquement ce sous-warning (placé après les flags projet → prime).
%global optflags %{optflags} -Wno-error=incompatible-pointer-types-discards-qualifiers

Summary:	Tools to handle creating and mounting composefs images
Name:		composefs
Version:	1.0.8
Release:	1
License:	LGPLv2+ and Apache-2.0
URL:		https://github.com/containers/composefs
Source0:	https://github.com/containers/composefs/releases/download/v%{version}/%{name}-%{version}.tar.xz

BuildRequires:	gcc
BuildRequires:	meson
BuildRequires:	pkgconfig(openssl)
BuildRequires:	pkgconfig(fuse3)
%if %{with man}
BuildRequires:	go-md2man
%endif

Requires:	%{libname} = %{EVRD}

%description
Tools to handle creating and mounting composefs images. The composefs
project combines several underlying Linux features (overlayfs, EROFS and
fs-verity) to provide a flexible mechanism for read-only mountable
filesystem trees. It is the immutable-root backend used by ostree/bootc.

%package -n %{libname}
Summary:	Shared library for %{name}
Group:		System/Libraries

%description -n %{libname}
Shared library files for %{name}.

%package -n %{develname}
Summary:	Development files for %{name}
Group:		Development/C
Requires:	%{name} = %{EVRD}
Requires:	%{libname} = %{EVRD}

%description -n %{develname}
Header files and pkgconfig data needed to build software using %{name}
(e.g. ostree built with --with-composefs).

%prep
%autosetup -p1

%build
%meson \
    --default-library=shared \
    -Dfuse=enabled \
%if %{without man}
    -Dman=disabled
%endif
%meson_build

%install
%meson_install
find %{buildroot} -name 'libcomposefs*.a' -delete

%files
%license COPYING COPYING.GPL-2.0-only COPYING.GPL-2.0-or-later COPYING.LGPL-2.1-or-later LICENSE.Apache-2.0
%doc README.md
%{_bindir}/mkcomposefs
%{_bindir}/composefs-info
%{_sbindir}/mount.composefs
%if %{with man}
%{_mandir}/man*/*
%endif

%files -n %{libname}
%{_libdir}/libcomposefs.so.%{major}*

%files -n %{develname}
%{_includedir}/libcomposefs
%{_libdir}/libcomposefs.so
%{_libdir}/pkgconfig/%{name}.pc
