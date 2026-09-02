# Bundled SVN runtime

Debug and Release builds use the same relocatable, signed arm64 SVN runtime at:

```text
Vendor/SVNRuntime/
├── bin/svn
├── etc/ssl/cert.pem
├── lib/*.dylib
├── licenses/*
├── BUILD-INFO.txt
└── SHA256SUMS
```

The directory is copied into the application Resources as `SVNRuntime`. `bin/svn` and every bundled dylib use `@loader_path` references; the installed application has no Homebrew or shell-environment dependency. The committed files carry ad-hoc signatures for unsigned local builds and are re-signed as nested code by Xcode when code signing is enabled.

Regenerate the runtime from an arm64 Homebrew installation with:

```sh
Scripts/package-svn-runtime.sh /opt/homebrew/bin/svn
```

Homebrew is a packaging input on the developer machine only. It is not required on an end user's Mac. The script recursively copies all non-system libraries, bundles the public Mozilla CA store, rewrites load commands, collects available license and notice files, signs the result ad hoc, records checksums and validates HTTPS support. It deliberately packages the public CA source file rather than Homebrew's generated `etc/ca-certificates/cert.pem`, which may contain private enterprise or developer roots from the packaging Mac's Keychain.

The application resolves this runtime before any Debug-only override or external fallback. Do not commit credentials, SVN configuration, auth caches or certificates into this directory.
