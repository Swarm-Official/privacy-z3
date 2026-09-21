#!/usr/bin/env python3
"""Print one difficulty sample of the live chain as JSON, from inside the stack.

Runs in the ops image, on the stack's internal network:

    docker run --rm --network <project> \
        -v <project>-auth:/swarm/auth:ro --user 10001:10001 \
        -e SWARM_ZEBRA_RPC=zebra:18232 \
        -v /opt/swarm/verify:/verify:ro swarm-ops:local \
        python3 /verify/difficulty-sample.py [window]

Standard library only, and one process rather than one container per RPC call.
The cookie is read from the shared volume and never printed.
"""

import base64
import json
import os
import sys
import urllib.request

COOKIE = os.environ.get("SWARM_COOKIE_FILE", "/swarm/auth/.cookie")
ADDRESS = os.environ.get("SWARM_ZEBRA_RPC", "zebra:18232")


def rpc(method, params=None):
    token = open(COOKIE, encoding="utf-8").read().strip()
    if token.startswith("__cookie__:"):
        token = token[len("__cookie__:"):]
    auth = base64.b64encode(f"__cookie__:{token}".encode()).decode()
    body = json.dumps({"jsonrpc": "2.0", "id": "swarm-difficulty",
                       "method": method, "params": params or []}).encode()
    request = urllib.request.Request(
        f"http://{ADDRESS}",
        data=body,
        headers={"content-type": "application/json", "authorization": f"Basic {auth}"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    if payload.get("error"):
        raise SystemExit(f"{method} failed: {payload['error']}")
    return payload["result"]


def main():
    window = int(sys.argv[1]) if len(sys.argv) > 1 else 25
    info = rpc("getblockchaininfo")
    height = info["blocks"]

    headers = []
    for h in range(max(1, height - window + 1), height + 1):
        block = rpc("getblock", [str(h), 1])
        headers.append({
            "height": h,
            "time": block["time"],
            "difficulty": block.get("difficulty"),
            "bits": block.get("bits"),
            "hash": block["hash"],
        })

    print(json.dumps({
        "height": height,
        "tip_hash": info["bestblockhash"],
        "difficulty": info["difficulty"],
        "bits": info.get("bits"),
        "headers": headers,
    }))


if __name__ == "__main__":
    main()
