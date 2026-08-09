# terminus-nix

A NixOS module that runs [usetrmnl/terminus](https://github.com/usetrmnl/terminus)
(a self-hosted TRMNL server) as a rootful **podman** OCI-container stack, modelled
on the upstream `compose.yml`.

The stack is four containers on a private podman bridge network (`terminus-net`):

| Container           | Image (pinned by digest)         | Exposed        |
| ------------------- | -------------------------------- | -------------- |
| `terminus-database` | `postgres:18.4-alpine`           | internal only  |
| `terminus-keyvalue` | `valkey/valkey:9.1-alpine`       | internal only  |
| `terminus-web`      | `ghcr.io/usetrmnl/terminus:0.68.0` | host `:2300` |
| `terminus-worker`   | `ghcr.io/usetrmnl/terminus:0.68.0` | internal only  |

`terminus-web` runs `hanami db migrate` on startup (`APP_SETUP=true`), so there is
no separate migration step — the module only gates the web container on Postgres
being ready.

## Usage

Add this flake as an input and import `nixosModules.terminus`:

```nix
# flake.nix
inputs.terminus.url = "git+ssh://git@github.com/Sammyalhashe/terminus-nix.git";
inputs.terminus.inputs.nixpkgs.follows = "nixpkgs"; # avoid a second nixpkgs
```

```nix
# in a host module
{ config, inputs, ... }:
{
  imports = [ inputs.terminus.nixosModules.terminus ];

  services.terminus = {
    enable = true;
    apiUri = "http://192.168.1.50:2300";        # LAN address devices connect to
    environmentFile = config.sops.secrets.terminus_env.path;
  };
}
```

Requires podman on the host: `virtualisation.podman.enable = true;` (the module
enables it and sets `virtualisation.oci-containers.backend = "podman"` by default).

## Secrets — `environmentFile`

Provide an env file (e.g. a sops-nix secret) with these keys. `APP_SECRET` and the
passwords are secret; keep the file out of the nix store.

```sh
APP_SECRET=<hex string, generate once: openssl rand -hex 64>
DATABASE_URL=postgres://terminus:<db-pass>@database:5432/terminus
KEYVALUE_URL=redis://:<kv-pass>@keyvalue:6379/0
POSTGRES_USER=terminus
POSTGRES_DB=terminus
POSTGRES_PASSWORD=<db-pass>
KEYVALUE_PASSWORD=<kv-pass>
```

`<db-pass>` must be identical in `DATABASE_URL` and `POSTGRES_PASSWORD`;
`<kv-pass>` identical in `KEYVALUE_URL` and `KEYVALUE_PASSWORD`. The hostnames
`database` / `keyvalue` are podman network aliases and should not be changed.

## Options

- `services.terminus.enable`
- `services.terminus.image` / `postgresImage` / `valkeyImage` — pinned refs
- `services.terminus.port` (default `2300`)
- `services.terminus.apiUri`
- `services.terminus.environmentFile`
- `services.terminus.openFirewall` (default `true`)

## Upgrading

Bump `services.terminus.image` to a new tag+digest and rebuild. Get the
manifest-list digest for a tag with:

```sh
skopeo inspect --raw docker://ghcr.io/usetrmnl/terminus:<tag> | sha256sum
```
