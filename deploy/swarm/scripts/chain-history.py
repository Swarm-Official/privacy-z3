#!/usr/bin/env python3
"""Dump every block header of the live chain as JSON, from inside the stack.

    docker run --rm --network <project> \
        -v <project>-auth:/swarm/auth:ro --user 10001:10001 \
        -e SWARM_ZEBRA_RPC=zebra:18232 \
        -v /opt/swarm/verify:/verify:ro <ops image> \
        python3 /verify/chain-history.py [from] [to]

One line of JSON per block on stdout, so a long chain streams instead of being
assembled in memory. For each height: time, difficulty, compact target, and who
mined it.

"Who mined it" is read off the coinbase, not guessed. A block this server mined
pays the baseline miner a transparent output; a block the owner's PC mined pays
a unified address, so its coinbase carries an `ironwood` shielded bundle and
only the three transparent allocation outputs. That distinction is the whole
point of the per-window miner split.

Standard library only, one process rather than one container per call, and the
RPC cookie is read from the shared volume and never printed.
"""

import base64
import json
import os
import sys
import urllib.request

COOKIE = os.environ.get("SWARM_COOKIE_FILE", "/swarm/auth/.cookie")
ADDRESS = os.environ.get("SWARM_ZEBRA_RPC", "zebra:18232")
BASELINE_MINER = os.environ.get("SWARM_MINER_ADDRESS", "")

_auth = None


def rpc(method, params=None):
    global _auth
    if _auth is None:
        token = open(COOKIE, encoding="utf-8").read().strip()
        if token.startswith("__cookie__:"):
            token = token[len("__cookie__:"):]
        _auth = base64.b64encode(f"__cookie__:{token}".encode()).decode()
    body = json.dumps({"jsonrpc": "2.0", "id": "swarm-history",
                       "method": method, "params": params or []}).encode()
    request = urllib.request.Request(
        f"http://{ADDRESS}", data=body,
        headers={"content-type": "application/json", "authorization": f"Basic {_auth}"})
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.load(response)
    if payload.get("error"):
        raise SystemExit(f"{method} failed: {payload['error']}")
    return payload["result"]


def main():
    tip = rpc("getblockchaininfo")["blocks"]
    first = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    last = int(sys.argv[2]) if len(sys.argv) > 2 else tip

    for height in range(first, last + 1):
        block = rpc("getblock", [str(height), 2])
        coinbase = block["tx"][0] if block.get("tx") else {}

        transparent = {}
        for output in coinbase.get("vout", []):
            for address in output["scriptPubKey"].get("addresses", []):
                transparent[address] = transparent.get(address, 0) + int(output["valueZat"])

        # Negative value balance means value entering the pool.
        shielded_in = 0
        for pool in ("ironwood", "orchard"):
            bundle = coinbase.get(pool)
            if isinstance(bundle, dict):
                shielded_in += -int(bundle.get("valueBalanceZat", 0))
        shielded_in += -int(coinbase.get("valueBalanceZat", 0) or 0)

        if shielded_in > 0:
            miner = "other"
        elif BASELINE_MINER and BASELINE_MINER in transparent:
            miner = "server"
        elif height == 0:
            miner = "genesis"
        else:
            miner = "unknown"

        print(json.dumps({
            "height": height,
            "hash": block["hash"],
            "time": block["time"],
            "bits": block.get("bits"),
            "difficulty": block.get("difficulty"),
            "miner": miner,
            "coinbase_transparent_zatoshi": sum(transparent.values()),
            "coinbase_shielded_in_zatoshi": shielded_in,
        }))


if __name__ == "__main__":
    main()
