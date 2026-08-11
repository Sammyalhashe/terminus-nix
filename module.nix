# NixOS module to run usetrmnl/terminus (a TRMNL server) as a rootful podman
# OCI-container stack. Modelled on the upstream compose.yml
# (https://github.com/usetrmnl/terminus/blob/main/compose.yml).
#
# The stack is four containers on a private podman bridge network:
#   database (PostgreSQL) and keyvalue (Valkey) — internal only, not published
#   web      (Hanami/puma) — the only published port; self-migrates on start
#   worker   (Sidekiq)
#
# The `web` container runs `hanami db migrate` on startup because APP_SETUP=true
# (see scripts/docker/entrypoint upstream), so no separate migration unit is
# needed — we only gate it on Postgres accepting connections.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.terminus;
  net = "terminus-net";
  target = "${cfg.backend}-compose-terminus-root.target";
  netUnit = "${cfg.backend}-network-${net}.service";
  backendPkg = config.virtualisation.${cfg.backend}.package;

  # Common systemd wiring for each container, mirroring the compose2nix pattern
  # already used on this host: always-restart, ordered after the network unit,
  # and bound to the stack's root target.
  mkUnit =
    {
      after ? [ ],
      requires ? [ ],
    }:
    {
      serviceConfig.Restart = lib.mkOverride 90 "always";
      after = [ netUnit ] ++ after;
      requires = [ netUnit ] ++ requires;
      partOf = [ target ];
      wantedBy = [ target ];
    };
in
{
  options.services.terminus = {
    enable = lib.mkEnableOption "TRMNL Terminus server (podman OCI stack)";

    backend = lib.mkOption {
      type = lib.types.enum [ "podman" "docker" ];
      default = "podman";
      description = "Which virtualisation backend to use. [Default: podman]";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/usetrmnl/terminus:0.68.0@sha256:5e5fe4ff058f50ca8cee06d864126d62caa87e51952b3751f8d180ba659f60c4";
      description = "Pinned terminus web/worker image (tag + manifest-list digest).";
    };

    postgresImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/library/postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15";
      description = "Pinned PostgreSQL image (matches upstream compose).";
    };

    valkeyImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/valkey/valkey:9.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328";
      description = "Pinned Valkey (Redis-compatible) image (matches upstream compose).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 2300;
      description = "Host port to publish the web UI/API on (HANAMI_PORT).";
    };

    apiUri = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.port}";
      example = "http://11.125.37.175:2300";
      description = ''
        Base URL that TRMNL devices use to reach this server (API_URI). On a LAN,
        set this to http://<host-lan-ip>:<port>.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/terminus_env";
      description = ''
        Path to an env file (e.g. a sops-nix secret) providing the secret-bearing
        variables. Expected keys:
          APP_SECRET
          DATABASE_URL       (postgres://<user>:<pass>@database:5432/<db>)
          KEYVALUE_URL       (redis://:<pass>@keyvalue:6379/0)
          POSTGRES_USER
          POSTGRES_DB
          POSTGRES_PASSWORD
          KEYVALUE_PASSWORD
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the web port in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = lib.mkIf (cfg.backend == "podman") true;
    virtualisation.docker.enable = lib.mkIf (cfg.backend == "docker") true;
    virtualisation.oci-containers.backend = lib.mkDefault cfg.backend;

    # --- PostgreSQL (internal only) ---
    virtualisation.oci-containers.containers.terminus-database = {
      image = cfg.postgresImage;
      environmentFiles = [ cfg.environmentFile ];
      cmd = [
        "-p"
        "5432"
      ];
      volumes = [ "terminus-database-data:/var/lib/postgresql" ];
      log-driver = "journald";
      extraOptions = [
        "--network=${net}"
        "--network-alias=database"
        "--health-cmd=pg_isready -p 5432 -q"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=3"
      ];
    };
    systemd.services."${cfg.backend}-terminus-database" = mkUnit { };

    # --- Valkey (internal only); requirepass is read from the env file so the
    # secret never lands in the nix store. ---
    virtualisation.oci-containers.containers.terminus-keyvalue = {
      image = cfg.valkeyImage;
      environmentFiles = [ cfg.environmentFile ];
      cmd = [
        "sh"
        "-c"
        "exec valkey-server --requirepass \"$KEYVALUE_PASSWORD\" --maxmemory 512mb --maxmemory-policy noeviction --port 6379"
      ];
      volumes = [ "terminus-keyvalue-data:/data" ];
      log-driver = "journald";
      extraOptions = [
        "--network=${net}"
        "--network-alias=keyvalue"
        "--health-cmd=valkey-cli -a \"$KEYVALUE_PASSWORD\" --no-auth-warning ping"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=3"
      ];
    };
    systemd.services."${cfg.backend}-terminus-keyvalue" = mkUnit { };

    # --- Web (Hanami/puma); self-migrates via APP_SETUP=true ---
    virtualisation.oci-containers.containers.terminus-web = {
      image = cfg.image;
      environment = {
        HANAMI_PORT = toString cfg.port;
        API_URI = cfg.apiUri;
        APP_SETUP = "true";
      };
      environmentFiles = [ cfg.environmentFile ];
      volumes = [
        "terminus-web-fonts:/app/public/fonts"
        "terminus-web-fonts:/usr/share/fonts/terminus"
        "terminus-web-uploads:/app/public/uploads"
      ];
      ports = [ "${toString cfg.port}:${toString cfg.port}" ];
      log-driver = "journald";
      extraOptions = [
        "--init"
        "--network=${net}"
        "--network-alias=web"
        "--health-cmd=curl --fail --silent http://localhost:${toString cfg.port}/up"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
        "--health-start-period=45s"
      ];
    };
    systemd.services."${cfg.backend}-terminus-web" = mkUnit {
      after = [ "terminus-db-ready.service" ];
      requires = [ "terminus-db-ready.service" ];
    };

    # --- Worker (Sidekiq) ---
    virtualisation.oci-containers.containers.terminus-worker = {
      image = cfg.image;
      environment = {
        HANAMI_PORT = toString cfg.port;
        API_URI = cfg.apiUri;
      };
      environmentFiles = [ cfg.environmentFile ];
      cmd = [
        "bundle"
        "exec"
        "sidekiq"
        "-r"
        "./config/sidekiq.rb"
      ];
      volumes = [
        "terminus-web-fonts:/app/public/fonts"
        "terminus-web-fonts:/usr/share/fonts/terminus"
        "terminus-web-uploads:/app/public/uploads"
      ];
      log-driver = "journald";
      extraOptions = [
        "--init"
        "--network=${net}"
        "--network-alias=worker"
        "--health-cmd=pgrep -f sidekiq"
        "--health-interval=30s"
        "--health-timeout=10s"
        "--health-retries=3"
        "--health-start-period=45s"
      ];
    };
    systemd.services."${cfg.backend}-terminus-worker" = mkUnit {
      after = [ "${cfg.backend}-terminus-web.service" ];
      requires = [ "${cfg.backend}-terminus-web.service" ];
    };

    # --- Gate web's start (and thus its migration) on Postgres readiness ---
    systemd.services.terminus-db-ready = {
      description = "Wait for Terminus PostgreSQL to accept connections";
      after = [ "${cfg.backend}-terminus-database.service" ];
      requires = [ "${cfg.backend}-terminus-database.service" ];
      before = [ "${cfg.backend}-terminus-web.service" ];
      partOf = [ target ];
      wantedBy = [ target ];
      path = [ backendPkg ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "180";
      };
      script = ''
        until ${cfg.backend} exec terminus-database pg_isready -p 5432 -q; do
          echo "waiting for postgres to be ready..."
          sleep 2
        done
      '';
    };

    # --- Private bridge network + root target (compose2nix pattern) ---
    systemd.services."${cfg.backend}-network-${net}" = {
      path = [ backendPkg ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "${cfg.backend} network rm -f ${net}";
      };
      script = "${cfg.backend} network inspect ${net} || ${cfg.backend} network create ${net} --driver=bridge";
      partOf = [ target ];
      wantedBy = [ target ];
    };

    systemd.targets."${cfg.backend}-compose-terminus-root" = {
      unitConfig.Description = "Root target for the Terminus podman stack.";
      wantedBy = [ "multi-user.target" ];
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
