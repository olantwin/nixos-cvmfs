# nixos-cvmfs

A Nix flake that packages the [CernVM File System](https://cernvm.cern.ch/fs/) (CVMFS) client for NixOS with a declarative NixOS module and systemd automount support.

## What's included

- **CVMFS 2.13.3 client package** — built from source with patches for NixOS's non-FHS layout
- **NixOS module** (`services.cvmfs`) — declarative configuration, automatic `/etc/cvmfs/` management, and systemd `.mount`/`.automount` units per repository

## Usage

Add this flake to your system flake's inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixos-cvmfs = {
      url = "github:youruser/nixos-cvmfs";  # adjust URL
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixos-cvmfs, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        nixos-cvmfs.nixosModules.cvmfs
        {
          services.cvmfs = {
            enable = true;
            package = nixos-cvmfs.packages.x86_64-linux.cvmfs;
            repositories = [
              "cvmfs-config.cern.ch"
              "sft.cern.ch"
            ];
          };
        }
      ];
    };
  };
}
```

After `nixos-rebuild switch`, accessing `/cvmfs/sft.cern.ch/` triggers the automount.

## Module options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable CernVM-FS client with systemd automount |
| `package` | package | — | The CVMFS package to use |
| `repositories` | list of str | `[]` | Repository FQRNs to automount at `/cvmfs/<repo>` |
| `httpProxy` | null or str | `"DIRECT"` | HTTP proxy (`"DIRECT"`, `"auto"`, or a URL) |
| `quotaLimit` | null or int | `4000` | Cache soft limit in MB |
| `cacheBase` | null or str | `"/var/cache/cvmfs"` | Cache directory |
| `clientProfile` | null or `"single"` | `"single"` | `"single"` for laptops (enables WPAD proxy discovery) |
| `extraConfig` | attrs of str | `{}` | Additional key-value pairs for `default.local` |
| `extraRepoConfig` | attrs of str | `{}` | Per-repo config (key = FQRN, value = config content) |
| `automountIdleTimeout` | str | `"600"` | Seconds of inactivity before unmount (`"0"` = never) |
| `unmountOnSuspend` | bool | `true` | Unmount all repositories before suspend/hibernate so stale FUSE handles don't survive a sleep |

## What the module sets up

- Creates a `cvmfs` system user and group
- Loads the `fuse` kernel module and enables `user_allow_other`
- Populates `/etc/cvmfs/` with config files and CERN/EGI/OSG public keys
- Generates `/etc/cvmfs/default.local` from module options
- Creates systemd `.mount` and `.automount` units for each repository
- Creates the cache directory at `cacheBase`

## NixOS-specific patches

CVMFS assumes an FHS layout (`/usr/bin`, `/usr/lib`, `/sbin`, etc.) which doesn't exist on NixOS. This package applies the following patches:

- `mount.cvmfs` binary path: `/usr/bin` -> `$out/bin`
- `cvmfs2` library search: adds `$out/lib/` for `dlopen()` of `libcvmfs_fuse*.so`
- Authz helper path: `/usr/libexec/cvmfs/authz` -> `$out/libexec/cvmfs/authz`
- Mount helper install: `/sbin` -> `$out/bin`
- Systemd unit install: `/usr/lib/systemd/system` -> `$out/lib/systemd/system`
- LibreSSL guard: removed (uses system OpenSSL, which is API-compatible)
- Autofs symlink: removed (we use systemd automount)
- RPATH: `$ORIGIN` added to `libcvmfs_fuse3.so` so it finds sibling libraries

Three vendored libraries (vjson, sha3, pacparser) are built from CVMFS's bundled sources since they're not available in nixpkgs or are broken there.

## License

MIT
