#!/usr/bin/env python3
"""Turn the rendered SwarmTestnet configs into this deployment's config directory.

The rendered files come from workstream A and describe the *chain*. A few
values in them describe a *machine* instead - how many CPUs it has, which peers
it dials, where its data lives - and those differ on the seed server. This
script applies exactly those, and nothing else.

What it changes, all outside the consensus block:

  zebrad.toml   initial_testnet_peers -> []     the seed must not dial itself:
                                                seed.swarm.green is this host
                [rpc]/[sync] parallel_cpu_threads -> 2   the box has 2 vCPUs
  zainod.toml   ephemeral_finalised_state -> false       the indexer database is
                                                a named volume, so it survives
                                                the restarts the cookie watcher
                                                triggers
                [storage.database] path -> /swarm/data/state
                sync_write_batch_size, accumulator_rebuild_memory_size -> 1 GiB
                                                (they default to 8 GiB, which is
                                                an instant OOM in a 1 GiB
                                                container)

What it refuses to change, and verifies byte-for-byte afterwards: the whole
`[network.testnet_parameters]` section of zebrad.toml, including the funding
streams and activation heights. That block is consensus. If this script ever
alters a byte of it, it fails instead of writing.

Everything else this deployment needs - listen addresses, the external address,
the state and cookie directories, the miner address - is applied at run time as
ZEBRA_*/ZAINO_* environment overrides by the container entrypoints, so the
rendered file on disk stays the chain's file.

    python3 seed-overlay.py --rendered <dir> --manifest <manifest.json> --out <dir>
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

CONSENSUS_SECTION = "[network.testnet_parameters]"


def consensus_block(text: str) -> str:
    """The `[network.testnet_parameters]` section and its subsections.

    Ends at the next top-level `[section]` that is not one of its children, so
    `[network.testnet_parameters.activation_heights]` stays inside it.
    """
    start = text.index(CONSENSUS_SECTION)
    rest = text[start + len(CONSENSUS_SECTION):]
    for match in re.finditer(r"^\[(?!network\.testnet_parameters)", rest, re.MULTILINE):
        return text[start:start + len(CONSENSUS_SECTION) + match.start()]
    return text[start:]


def substitute_once(text: str, pattern: str, replacement: str, what: str) -> str:
    updated, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        sys.exit(f"seed-overlay: expected exactly one {what}, found {count}")
    return updated


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rendered", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--genesis", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cpu-threads", type=int, default=2)
    parser.add_argument("--recipients", type=Path, default=None,
                        help="optional recipients.json for the explorer")
    args = parser.parse_args()

    seed_source = args.rendered / "zebra-seed.toml"
    zaino_source = args.rendered / "zaino.toml"
    for required in (seed_source, zaino_source, args.manifest, args.genesis):
        if not required.is_file():
            sys.exit(f"seed-overlay: no readable {required}")

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    expected_genesis = manifest["genesis"]["hash"]

    # ---- zebrad.toml -------------------------------------------------------
    seed = seed_source.read_text(encoding="utf-8")
    before = consensus_block(seed)
    if expected_genesis not in before:
        sys.exit("seed-overlay: the rendered seed config does not carry the manifest genesis hash")

    seed = substitute_once(
        seed,
        r"^initial_testnet_peers = \[.*\]$",
        "# The seed itself: seed.swarm.green resolves to this host, so dialling\n"
        "# it would be dialling itself. Other nodes put that name here.\n"
        "initial_testnet_peers = []",
        "initial_testnet_peers line",
    )
    seed, count = re.subn(
        r"^parallel_cpu_threads = \d+$",
        f"parallel_cpu_threads = {args.cpu_threads}",
        seed,
        flags=re.MULTILINE,
    )
    if count != 2:
        sys.exit(f"seed-overlay: expected two parallel_cpu_threads lines, found {count}")

    after = consensus_block(seed)
    if after != before:
        sys.exit("seed-overlay: the consensus block changed; refusing to write")

    # ---- zainod.toml -------------------------------------------------------
    zaino = zaino_source.read_text(encoding="utf-8")
    if expected_genesis not in zaino:
        sys.exit("seed-overlay: the rendered indexer config does not carry the manifest genesis hash")
    zaino = substitute_once(
        zaino,
        r"^ephemeral_finalised_state = .*$",
        "# A named volume, so the restarts the cookie watcher triggers cost a\n"
        "# reconnect and not a reindex.\nephemeral_finalised_state = false",
        "ephemeral_finalised_state line",
    )
    zaino = substitute_once(
        zaino,
        r'^path = ".*"$',
        'path = "/swarm/data/state"',
        "storage database path",
    )
    for key in ("sync_write_batch_size", "accumulator_rebuild_memory_size"):
        zaino = substitute_once(
            zaino,
            rf"^{key} = \d+$",
            f"{key} = 1",
            f"{key} line",
        )

    # ---- write -------------------------------------------------------------
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "zebrad.toml").write_text(seed, encoding="utf-8", newline="\n")
    (args.out / "zainod.toml").write_text(zaino, encoding="utf-8", newline="\n")
    shutil.copyfile(args.manifest, args.out / "manifest.json")
    shutil.copyfile(args.genesis, args.out / "genesis.hex")
    if args.recipients and args.recipients.is_file():
        shutil.copyfile(args.recipients, args.out / "recipients.json")

    print(f"seed-overlay: wrote {args.out}")
    print(f"  genesis      {expected_genesis}")
    print(f"  consensus    [network.testnet_parameters] unchanged, {len(before)} bytes")
    print(f"  cpu threads  {args.cpu_threads}")


if __name__ == "__main__":
    main()
