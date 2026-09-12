%define		debug_package %{nil}

Summary:	A command line utility performing various operations on container images and image repositories
Name:		skopeo
Version:	1.17.0
Release:	1
Group:		Development/Other
License:	ASL 2.0
URL:		https://github.com/containers/skopeo
Source0:	https://github.com/containers/skopeo/archive/v%{version}/%{name}-%{version}.tar.gz

BuildRequires:	go
BuildRequires:	git-core
BuildRequires:	pkgconfig(gpgme)
BuildRequires:	pkgconfig(devmapper)
BuildRequires:	upx

%description
skopeo is a command line utility that performs various
operations on container images and image repositories.

skopeo does not require the user to be running as root
to do most of its operations.

skopeo does not require a daemon to be running to perform
its operations.

skopeo can work with OCI images as well as the original
Docker v2 images.

Skopeo works with API V2 container image registries such
as docker.io and quay.io registries, private registries,
local directories and local OCI-layout directories.

%files
%license LICENSE
%doc README.md
%{_bindir}/%{name}

#--------------------------------------------------------------------

%prep
%autosetup

%build
CGO_CFLAGS="" \
CGO_LDFLAGS="-L%{_libdir} -lgpgme -lassuan -lgpg-error" \
GO111MODULE=on \
go build \
	-mod=vendor "-buildmode=pie" \
	-ldflags '-X main.gitCommit= ' \
	-gcflags "" \
	-tags "btrfs_noversion exclude_graphdriver_btrfs " \
	-o bin/skopeo \
	./cmd/skopeo

upx bin/%{name}


%install
install -Dm 0755 bin/%{name} %{buildroot}%{_bindir}/%{name}

