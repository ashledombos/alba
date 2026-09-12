# Alba — brique #6 : shim (build from-source, NON signé, POC)
# OMV n'a pas de shim buildé. On construit shimx64.efi depuis les sources amont
# (rhboot/shim 16.1) avec un certificat vendor auto-généré. NON signé Microsoft
# → convient à un POC en VM avec Secure Boot désactivé (OVMF). shim chaîne le
# grub d'OMV (grub.efi) via DEFAULT_LOADER.
#
# But : fournir /boot/efi/EFI/openmandriva/shimx64.efi RPM-owned, requis par
# bootupd (const SHIM=shimx64.efi + rpm -qf sur les fichiers EFI).

%global efidir openmandriva
# binaire EFI : pas de debuginfo/debugsource extractibles (objcopy PE)
%global debug_package %{nil}

Name:		shim
Version:	16.1
Release:	1
Summary:	First-stage UEFI bootloader (shim) — build POC non signé pour Alba
License:	BSD-2-Clause
URL:		https://github.com/rhboot/shim
Source0:	https://github.com/rhboot/shim/releases/download/%{version}/shim-%{version}.tar.bz2
ExclusiveArch:	x86_64

BuildRequires:	gcc
BuildRequires:	make
BuildRequires:	git
BuildRequires:	pkgconfig(libelf)
BuildRequires:	pkgconfig(openssl)
BuildRequires:	openssl
BuildRequires:	dos2unix
BuildRequires:	findutils

%description
Shim est le premier étage du démarrage UEFI : il est lancé par le firmware et
chaîne le bootloader (grub). Ce paquet est un build POC non signé pour Alba
(Secure Boot désactivé).

%prep
%autosetup -n shim-%{version}
# certificat vendor auto-signé (POC) — shim exige un cert à embarquer
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
	-subj "/CN=Alba POC vendor/" -keyout vendor.key -out vendor.crt
openssl x509 -in vendor.crt -outform DER -out vendor.der

%build
# shim ne se linke pas avec lld (OMV par défaut) : ".dynamic not contiguous with
# relro". On force GNU ld (ld.bfd) pour l'édition de liens EFI.
# binutils ≥ 2.46 : --target impose le format à l'ENTRÉE aussi (le .so ELF
# n'est alors « pas reconnu ») → --output-target ne contraint que la sortie.
make %{?_smp_mflags} \
	LD=ld.bfd \
	FORMAT='--output-target efi-app-x86_64' \
	COMMIT_ID=%{version} \
	VENDOR_CERT_FILE=$(pwd)/vendor.der \
	EFIDIR=%{efidir} \
	ENABLE_SHIM_HASH=true \
	DEFAULT_LOADER='\\\\grub.efi' \
	shimx64.efi

%install
install -D -d -m0700 %{buildroot}/boot/efi/EFI/%{efidir}
install -m0644 shimx64.efi %{buildroot}/boot/efi/EFI/%{efidir}/shimx64.efi
[ -f mmx64.efi ]   && install -m0644 mmx64.efi   %{buildroot}/boot/efi/EFI/%{efidir}/mmx64.efi   || true
[ -f fbx64.efi ]   && install -m0644 fbx64.efi   %{buildroot}/boot/efi/EFI/%{efidir}/fbx64.efi   || true
[ -f BOOTX64.CSV ] && install -m0644 BOOTX64.CSV %{buildroot}/boot/efi/EFI/%{efidir}/BOOTX64.CSV || true
[ -f shimx64.hash ] && install -m0644 shimx64.hash %{buildroot}/boot/efi/EFI/%{efidir}/ || true

%files
/boot/efi/EFI/%{efidir}/
