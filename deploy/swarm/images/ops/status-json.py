#!/usr/bin/env python3
"""Write the public status.json the website and the node app read.

Runs in the ops image on the stack's internal network, every 30 seconds, and
writes one small JSON file that Caddy serves as a static file at
https://lwd.swarm.green/status.json.

    python3 /usr/local/bin/swarm-status-json --out /swarm/public/status.json

WHAT GOES IN IT is decided by one rule: it is already public, or it is derivable
by anyone with the chain. Heights, hashes, difficulty, timings, how many peers,
whether each service is up. Nothing else.

WHAT NEVER GOES IN IT: the RPC cookie, obviously - but also peer addresses,
container names, internal hostnames and ports, file paths, and anything that
describes how this machine is put together. The node's RPC is not reachable
from the internet and this file must not become a way to map it.

The file is written atomically, so a reader never sees half of one. If a source
is unreachable the field says so and the file is still written: a status page
that vanishes when something breaks is a status page that is useless exactly
when it matters.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import json
import os
import socket
import sys
import time
import urllib.request
from pathlib import Path

COOKIE = os.environ.get("SWARM_COOKIE_FILE", "/swarm/auth/.cookie")
ZEBRA_RPC = os.environ.get("SWARM_ZEBRA_RPC", "zebra:18232")
ZAINO_GRPC = os.environ.get("SWARM_ZAINO_GRPC", "zaino:9067")
EXPLORER = os.environ.get("SWARM_EXPLORER_HEALTH", "http://explorer:4000/healthz")
CONFIG_DIR = Path(os.environ.get("SWARM_CONFIG_DIR", "/swarm/config"))

SERVICE = "/cash.z.wallet.sdk.rpc.CompactTxStreamer"


def utc(timestamp: float | int) -> str:
    return datetime.datetime.fromtimestamp(
        int(timestamp), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def rpc(method: str, params=None):
    token = Path(COOKIE).read_text(encoding="utf-8").strip()
    if token.startswith("__cookie__:"):
        token = token[len("__cookie__:"):]
    auth = base64.b64encode(f"__cookie__:{token}".encode()).decode()
    body = json.dumps({"jsonrpc": "2.0", "id": "swarm-status",
                       "method": method, "params": params or []}).encode()
    request = urllib.request.Request(
        f"http://{ZEBRA_RPC}", data=body,
        headers={"content-type": "application/json", "authorization": f"Basic {auth}"})
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = json.load(response)
    if payload.get("error"):
        raise RuntimeError(f"{method}: {payload['error']}")
    return payload["result"]


def tcp_open(address: str, timeout: float = 5.0) -> bool:
    host, _, port = address.rpartition(":")
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except (OSError, ValueError):
        return False


def http_ok(url: str, timeout: float = 8.0) -> tuple[bool, dict | None]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            if response.status != 200:
                return False, None
            try:
                return True, json.load(response)
            except (ValueError, UnicodeDecodeError):
                return True, None
    except Exception:
        return False, None


def mean_interval(times: list[int]) -> float | None:
    if len(times) < 2:
        return None
    gaps = [b - a for a, b in zip(times, times[1:])]
    return round(sum(gaps) / len(gaps), 1)


def build() -> dict:
    now = time.time()
    status: dict = {
        "schema": "swarm-network-status/1",
        "network": None,
        "server_time_utc": utc(now),
        "generated_unix": int(now),
        "refresh_seconds": int(os.environ.get("SWARM_STATUS_INTERVAL", "30")),
        "note": "Public, read-only, generated on the SWARM seed server. Engineering testnet: these coins have no value.",
    }

    manifest_path = CONFIG_DIR / "manifest.json"
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            status["network"] = manifest.get("identity", {}).get("network_name")
            status["ticker"] = manifest.get("identity", {}).get("ticker")
            status["chain_label"] = manifest.get("identity", {}).get("light_wallet_chain_label")
            status["genesis_hash"] = manifest.get("genesis", {}).get("hash")
            status["target_spacing_seconds"] = manifest.get("consensus", {}).get(
                "target_spacing_seconds")
        except (ValueError, OSError):
            pass

    node = {"up": False}
    try:
        info = rpc("getblockchaininfo")
        tip = int(info["blocks"])
        node.update({
            "up": True,
            "height": tip,
            "tip_hash": info["bestblockhash"],
            "difficulty": round(float(info["difficulty"]), 6),
        })

        # The headers behind the tip, for the two spacing figures. 101 headers
        # give 100 intervals; the same list gives the 20-block figure.
        times: list[int] = []
        bits = None
        for height in range(max(1, tip - 100), tip + 1):
            header = rpc("getblock", [str(height), 1])
            times.append(int(header["time"]))
            if height == tip:
                bits = header.get("bits")
                node["tip_time_utc"] = utc(header["time"])
        node["bits"] = bits
        node["mean_interval_last_20_seconds"] = mean_interval(times[-21:])
        node["mean_interval_last_100_seconds"] = mean_interval(times)
    except Exception as error:
        node["error"] = type(error).__name__

    # How many, never who. `getpeerinfo` returns one entry per connected peer
    # and every entry carries that peer's address; only the length of the list
    # leaves this machine, and the list itself is not held on to.
    #
    # The timestamp is the moment of the count, not the moment the file was
    # written. The header walk above makes up to 101 RPC calls and can take a
    # few seconds, so a reader showing this as "right now" deserves to know
    # how old "now" is.
    try:
        peers = rpc("getpeerinfo")
        node["peers"] = len(peers)
        node["peers_updated"] = utc(time.time())
        del peers
    except Exception:
        node["peers"] = None
        node["peers_updated"] = None

    status["node"] = node

    # The indexer's own height comes from the node's view of it being reachable
    # plus the explorer's report; a gRPC call needs HTTP/2, which the standard
    # library does not speak. Reachability is what a status page needs.
    indexer = {"up": tcp_open(ZAINO_GRPC)}
    status["indexer"] = indexer

    explorer_up, explorer_body = http_ok(EXPLORER)
    explorer = {"up": explorer_up}
    if isinstance(explorer_body, dict):
        if "height" in explorer_body:
            explorer["height"] = explorer_body["height"]
            # The explorer reads the node too, so its height is a second
            # opinion on the indexer's freshness.
            indexer.setdefault("height_via_explorer", explorer_body["height"])
        if "node" in explorer_body:
            explorer["node"] = explorer_body["node"]
    status["explorer"] = explorer

    status["healthy"] = bool(node.get("up") and indexer.get("up"))
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--loop", action="store_true",
                        help="keep regenerating every SWARM_STATUS_INTERVAL seconds")
    args = parser.parse_args()

    interval = int(os.environ.get("SWARM_STATUS_INTERVAL", "30"))
    args.out.parent.mkdir(parents=True, exist_ok=True)

    while True:
        try:
            status = build()
        except Exception as error:  # never let one bad read stop the loop
            status = {
                "schema": "swarm-network-status/1",
                "server_time_utc": utc(time.time()),
                "healthy": False,
                "error": type(error).__name__,
            }
        # Atomic: a reader never sees a half-written file.
        temporary = args.out.with_suffix(args.out.suffix + ".tmp")
        temporary.write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, args.out)
        os.chmod(args.out, 0o644)

        if not args.loop:
            print(json.dumps(status, indent=2))
            return 0
        sys.stdout.flush()
        time.sleep(interval)


if __name__ == "__main__":
    sys.exit(main())
