# SWARM testnet server stack

A self-contained deployment for the SwarmTestnet seed node, its baseline miner
and its public light-wallet indexer, on one small Linux server.

Why it lives in `deploy/swarm/` rather than in the z3 stack at the repository
root: that stack is a governed public contract (`z3-contract.yaml`, the parity
checks in `scripts/validate-contract*.py`, and the CI that enforces them). It
pins upstream images, ships Zallet and a monitoring profile, and its volume,
network and variable names are promised to downstream consumers. This
deployment has to run **project-built binaries** in its own images (the
official Zebra image has no internal miner), publish only the P2P port and
Caddy, run a one-shot genesis job, and handle the node's rotating RPC cookie
with its own uid scheme. Bending the root stack into that shape would break the
contract it publishes. So this folder borrows z3's patterns - env-file
parameterisation, named volumes, health-gated `depends_on` - and leaves the
contract alone.

## What runs

| Service | What it is | Published |
| --- | --- | --- |
| `zebra` | official Zebra v6.3.0 consensus, built with the `internal-miner` feature, running a configured Testnet. Always-on one-thread baseline miner. | P2P only, `18233/tcp` |
| `init-genesis` | one-shot: submits `genesis.hex` into an empty database, then proves the resulting hash matches the manifest | nothing |
| `zaino` | the light-wallet indexer, reporting the chain label `swarm-testnet` | nothing; reached by Caddy on the internal network |
| `caddy` | TLS for `lwd.swarm.green`, gRPC over HTTP/2 to the indexer | `80/tcp`, `443/tcp` |
| `explorer` | a disabled slot behind the `explorer` profile; image supplied later | nothing |

The node's JSON-RPC is never published to the host. It binds `0.0.0.0` inside
its container so the other containers can reach it by service name, and there
is no port mapping, so it is not reachable from outside. It requires cookie
authentication regardless.

## The short version

```sh
# 1. once, on the server, as root
scp -i ~/.ssh/swarm_server_ed25519 scripts/provision.sh root@SERVER:/root/
ssh -i ~/.ssh/swarm_server_ed25519 root@SERVER 'bash /root/provision.sh'

# 2. on the workstation: the images CI built, verified
scripts/fetch-artifacts.sh --images

# 3. the rendered configuration for the chain, from workstream A
cp -a /path/to/rendered/config ./config/live

# 4. fill in the five required values
cp .env.example .env && $EDITOR .env

# 5. deploy
scripts/deploy.sh --host SERVER --images ./dist --config ./config/live --env ./.env
```

Then, on the server:

```sh
/opt/swarm/scripts/swarm-stack status
/opt/swarm/scripts/swarm-stack health
```

The owner-facing procedure, including DNS, backups, updates and what must never
be copied to this machine, is `docs/SWARM-SERVER-RUNBOOK.md` in the project
repository.

## Nothing is built on the server

The server has 2 shared vCPUs and 4 GB of RAM, and a compiler has no business
on a machine that holds a chain. `zebrad` and `zainod` are built in GitHub
Actions with `--locked`; the stack workflow in this repository copies them into
the slim images, exercises the whole stack against a throwaway network, and
exports the images with `docker save`. `deploy.sh` uploads those tarballs and
`docker load`s them.

`--binaries` is the documented fallback: it uploads the two binaries and builds
the copy-only images on the server. It exists for the case where a CI artifact
has expired, and it still compiles nothing.

## The rotating RPC cookie

Zebra writes a fresh random RPC cookie on every start and deletes it on
shutdown. Zaino reads that file **once**, when it builds its RPC client, and
holds the token for the life of the process. After a node restart a running
indexer therefore authenticates with a secret that no longer exists, and keeps
doing so: it does not crash, it just stops being able to answer anything.

The handling is in `images/zaino/entrypoint.sh`, and has four parts:

1. **One uid.** Both images run as `10001:10001`, so the `0600` cookie Zebra
   writes into the shared volume is readable by the indexer with no privileged
   sidecar loosening its permissions. The `auth` volume inherits that ownership
   from the zebra image's `/swarm/auth` directory the first time it is created.
2. **Wait, then record.** The entrypoint blocks until a cookie exists and
   hashes it, so a cold start or a node restart never produces a configuration
   error about a missing file.
3. **Supervise, do not exec.** `zainod` installs no signal handlers - there is
   no `tokio::signal` anywhere in the Zaino tree - and the kernel discards
   SIGTERM sent to a PID 1 with no handler. As PID 1 it could neither be
   restarted from inside the container nor stopped by `docker stop`, only
   killed. So the entrypoint stays PID 1 and runs the indexer as a child,
   forwarding SIGTERM and SIGINT to it.
4. **Watch and restart.** The supervisor re-hashes the cookie every
   `SWARM_COOKIE_POLL_SECONDS`. If it changed - or if it has been missing
   longer than `SWARM_COOKIE_MISSING_GRACE_SECONDS`, which is a node that is
   not coming back with the same secret - it stops the indexer and exits
   non-zero. `restart: unless-stopped` brings the container back, and step 2
   picks up the new secret.

The indexer database is a named volume, so this costs a reconnect, not a
reindex. The reason is logged, and a restart loop is visible in
`docker compose ps`. The alternative - teaching Zaino to re-read the cookie per
request - is a source change to a fork whose rule is to change as little as
possible, and the CI job **proves** this path: it restarts the node and asserts
the indexer recovers by itself.

## Layout

```
deploy/swarm/
  docker-compose.yml     the stack
  Caddyfile              TLS, gRPC, the disabled explorer block
  .env.example           every variable, with its default
  images/
    zebra/               Dockerfile, entrypoint, health check
    zaino/               Dockerfile, entrypoint (cookie supervisor), health check
    ops/                 curl/jq/python3: genesis job, RPC helper, GetLightdInfo
  config/
    README.md            what the mounted configuration has to contain
    example/             a throwaway network for CI and first runs
    live/                the real rendered configuration (not in git)
  scripts/
    provision.sh         prepare a fresh Ubuntu server (root, over SSH)
    fetch-artifacts.sh   CI artifacts to the workstation, verified
    deploy.sh            workstation to server: upload, load, start, check
    healthcheck.sh       the full verdict, on the server
    swarm-stack          day-to-day operation, on the server
```

## What is not here

- **The faucet.** A slot in `.env.example` and nothing else. It holds a hot
  wallet, which is the reason it is not in this stack yet.
- **Monitoring.** Zebra exposes Prometheus metrics and the z3 repository has a
  working Grafana stack; wiring it in is a later step, and it costs memory this
  box does not have to spare today.
- **A second seed.** Zebra opens one outbound connection per peer IP, so a
  second seed needs its own address, and there is no DNS seeder for a custom
  network. `seed.swarm.green` is a static name with one A record per seed.
