%global debug_package %{nil}
%global __strip /bin/true

Name:           asmspeed
Version:        1.1.0
Release:        1%{?dist}
Summary:        Terminal internet speed test written in x86-64 assembly
License:        MIT
ExclusiveArch:  x86_64
Source0:        asmspeed
Source1:        asmspeed.1

%description
asmspeed measures latency, download and upload speed from the terminal. It is a
single ~12 KB static x86-64 executable written in assembly, with no libc and no
dependencies, and uses plain HTTP against speed.cloudflare.com.

%prep

%build

%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_bindir}/asmspeed
install -Dpm0644 %{SOURCE1} %{buildroot}%{_mandir}/man1/asmspeed.1

%files
%{_bindir}/asmspeed
%{_mandir}/man1/asmspeed.1*

%changelog
* Fri Nov 13 2026 asmspeed packagers <asmspeed@localhost> - 1.1.0-1
- Colour UI, chevron progress bar, connection info, quality scores
