# Bundled SVN runtime

Release builds expect a relocatable, signed SVN runtime at:

```text
Vendor/SVNRuntime/
├── bin/svn
└── lib/*.dylib
```

The directory is copied into the application Resources as `SVNRuntime`. `bin/svn` must use `@loader_path`/`@rpath` references for bundled libraries; Homebrew absolute paths are not accepted. All executables and dylibs must be built for the architectures shipped by the app and signed as nested code during distribution.

The source archive, exact build flags, licenses, notices and checksums for the packaged version must be recorded here before a Release archive is produced. Do not commit credentials, SVN configuration, auth caches or certificates into this directory.

Debug builds may fall back to `SVNCLIENT_SVN_PATH`, `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`. Release builds must not rely on those locations.
