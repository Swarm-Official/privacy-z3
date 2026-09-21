# Configuration mounted into the stack

Every service mounts one directory read-only at `/swarm/config`. It is the
single input that decides which chain this deployment is, and it is **not**
produced here: workstream A renders it from `network/swarm-testnet/manifest.json`
with `scripts/swarm/render_config.py`, and `scripts/deploy.sh` uploads it.

| File | Read by | What it decides |
| --- | --- | --- |
| `zebrad.toml` | zebra | network name, magic, genesis hash, target limit, activation heights, funding streams |
| `zainod.toml` | zaino | the `[network.CustomTestnet]` block: the genesis and schedule the indexer verifies against the node before it opens its index |
| `genesis.hex` | init-genesis | the serialised block submitted once into an empty database |
| `manifest.json` | init-genesis | `genesis_hash`, which the job proves the node actually ended up with |
| `recipients.json` | explorer (optional) | the three destination addresses and their labels, so the explorer can name the funding-stream outputs instead of printing upstream's slot names |

`recipients.json` is only needed when the explorer is enabled. Its shape is in
`example/recipients.example.json`; the addresses come from the same three
`t2…` destinations the manifest's funding streams pay, and the labels are the
project's (Core Development, Grants & Ecosystem, Community & Development
Reserve), because upstream's RPC reports them as "Electric Coin Company",
"Zcash Foundation" and "Major Grants". It holds addresses, never keys.

Rules the stack relies on:

- **UTF-8 without a byte-order mark.** A BOM makes Zebra's TOML parser fail
  with an unhelpful message, so the node entrypoint checks for one and says so.
  `scripts/deploy.sh` strips BOMs and CRLF on upload.
- **Deployment-specific values are not in these files.** The miner address, the
  public IP, the listen addresses, the state and cookie paths all arrive as
  environment overrides from `.env`, so the rendered configuration is the same
  bytes on every machine running this chain. Rotating the miner address does not
  re-render anything.
- **One directory per chain.** `SWARM_CONFIG_DIR` points at it. Pointing it at a
  different chain's manifest while the old chain's volume is still attached is
  caught by the genesis job, which refuses rather than mixing them.

## `live/` - the real thing

Not in git. `scripts/deploy.sh` uploads the rendered directory to
`/opt/swarm/config/live` on the server. It holds no secrets: a genesis block, a
hash and two configuration files are all public facts about the network.

## `example/` - a throwaway stand-in

What CI brings the stack up against, and what the first run on a fresh server
should use. It is deliberately **not** SwarmTestnet:

- network name `SwarmCiTestnet`, magic `[83,87,67,73]` (`SWCI`), so a node
  running it cannot talk to a SwarmTestnet node even by accident;
- `genesis.hex` is the deterministic engineering genesis of the retired
  `PrivacyTestnetV2` lab network, reused because any configured testnet with the
  same target limit and activation schedule accepts it, and because generating a
  fresh one needs an Equihash solver this folder does not contain. Its recipe is
  published (upstream historical genesis coinbase, time `1789862400`, compact
  target `2007ffff`, first solved nonce from zero) and it contains no key
  material and no spendable output;
- the miner is paid a well-known Zcash test address that nobody should expect to
  control;
- `funding_streams` has no recipients. The real network's 80 / 8 / 4 / 8 split
  needs three P2SH `t2...` destinations that do not exist yet, so **the reward
  split is not exercised by this fixture** - only the stack around it is.

Never deploy `example/` as the public network.
