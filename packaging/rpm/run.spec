Name:           run
Version:        %{version}
Release:        1%{?dist}
Summary:        Systems programming language compiler with Go simplicity and low-level control

License:        MIT
URL:            https://runlang.dev
Source0:        https://github.com/marsolab/runlang/releases/download/v%{version}/run-%{version}-linux-%{_run_arch}.tar.gz

Requires:       zig >= 0.15

# Disable debug package generation — we ship a pre-built binary.
%global debug_package %{nil}

# Disable binary stripping — the binary is already stripped at build time.
%define __strip /bin/true

%description
Run is a systems programming language that combines the simplicity and
readability of Go with fine-grained control over memory and hardware.
It features generational references for memory safety without a garbage
collector or borrow checker, green threads for concurrency, and compiles
to native code via C.

The compiler requires Zig (>= 0.15) as it uses 'zig cc' for C compilation
and linking.

%prep
%setup -q -n run-%{version}-linux-%{_run_arch}

%install
rm -rf %{buildroot}

mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/usr/local/lib
mkdir -p %{buildroot}/usr/local/include/run
mkdir -p %{buildroot}/usr/share/licenses/%{name}

install -m 0755 bin/run %{buildroot}/usr/local/bin/run
install -m 0644 lib/librunrt.a %{buildroot}/usr/local/lib/librunrt.a
cp -a include/run/*.h %{buildroot}/usr/local/include/run/

if [ -f LICENSE ]; then
    install -m 0644 LICENSE %{buildroot}/usr/share/licenses/%{name}/LICENSE
fi

%files
%license LICENSE
/usr/local/bin/run
/usr/local/lib/librunrt.a
/usr/local/include/run/

%changelog
