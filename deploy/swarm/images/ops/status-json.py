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
import re
import socket
import sys
import time
import urllib.request
from pathlib import Path

try:
    import maxminddb  # the IP-to-city reader; the image carries the database
except ImportError:  # without it, status.json still works; the live map degrades
    maxminddb = None

COOKIE = os.environ.get("SWARM_COOKIE_FILE", "/swarm/auth/.cookie")
ZEBRA_RPC = os.environ.get("SWARM_ZEBRA_RPC", "zebra:18232")
ZAINO_GRPC = os.environ.get("SWARM_ZAINO_GRPC", "zaino:9067")
EXPLORER = os.environ.get("SWARM_EXPLORER_HEALTH", "http://explorer:4000/healthz")
CONFIG_DIR = Path(os.environ.get("SWARM_CONFIG_DIR", "/swarm/config"))
GEOIP_DB = os.environ.get("SWARM_GEOIP_DB", "/swarm/geo/city.mmdb")

SERVICE = "/cash.z.wallet.sdk.rpc.CompactTxStreamer"

# The seed node itself. Its city is already public (swarm.green/data/swarm-map.json)
# and matches GeoIP of the server's own address, so it is a constant here rather
# than a lookup, and the live map and the published map cannot drift apart.
SEED_PLACE = {"city": "Dallas", "country": "US", "lon": -96.80, "lat": 32.78, "seed": True}

# getpeerinfo addresses look like "1.2.3.4:8333" or "[2001:db8::1]:8333".
_IP_RE = re.compile(r"^[0-9A-Fa-f:.]+")


def geo_reader():
    """Open the IP-to-city database, or None where it is absent."""
    if maxminddb is None:
        return None
    try:
        return maxminddb.open_database(GEOIP_DB)
    except Exception:
        return None


def ip_from_addr(addr):
    """The host part of a getpeerinfo `addr`, or None if it has none."""
    if not isinstance(addr, str) or not addr:
        return None
    host = addr.rsplit(":", 1)[0]
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    if _IP_RE.match(host):
        return host
    return None


def place_for_ip(reader, ip):
    """City/… for one IP, rounded to city level, or None. The IP is not kept."""
    if reader is None or not ip:
        return None
    try:
        record = reader.get(ip)
    except Exception:
        return None
    if not record:
        return None
    city = ((record.get("city") or {}).get("names") or {}).get("en") or ""
    country = ((record.get("country") or {}).get("iso_code")) or ""
    location = record.get("location") or {}
    lat = location.get("latitude")
    lon = location.get("longitude")
    if not city or lat is None or lon is None:
        return None
    return {
        "city": city[:80],
        "country": country[:8],
        "lon": round(float(lon), 2),
        "lat": round(float(lat), 2),
    }


def places_from_peers(peers, reader):
    """Aggregate connected peers by city. IPs are read and never held on to."""
    by_city = {}
    for peer in peers or []:
        place = place_for_ip(reader, ip_from_addr(peer.get("addr")))
        if place is None:
            continue
        key = f"{place['city']}|{place['country']}"
        if key not in by_city:
            by_city[key] = {**place, "count": 1}
        else:
            by_city[key]["count"] += 1
    return sorted(by_city.values(), key=lambda p: (-p["count"], p["city"]))


def build_map_live(peers, reader, server_time_utc):
    """The live heat-map file: the seed plus every currently connected node.

    This is the honest answer to "show the nodes that are live": a connection to
    the seed is the only thing the network itself proves about a node, so "live"
    means "connected to the seed right now", and a node that dropped vanishes
    with it. Cities come from an offline IP-to-city lookup and never finer than a
    city; no address is written to the file or anywhere else.
    """
    geoip = reader is not None
    peer_places = places_from_peers(peers, reader) if geoip else []

    # The seed joins the same aggregation, so a peer in the seed's own city
    # adds to one dot instead of drawing the city twice. The seed stays first.
    seed_match = next(
        (p for p in peer_places
         if (p["city"], p["country"]) == (SEED_PLACE["city"], SEED_PLACE["country"])),
        None,
    )
    if seed_match is not None:
        seed_match["count"] += 1
        seed_match["seed"] = True
        places = peer_places
        places.sort(key=lambda p: (not p.get("seed"), -p["count"], p["city"]))
    else:
        places = [dict(SEED_PLACE, count=1)] + peer_places

    online = 1 + len(peers or [])
    note = (
        "Nodes whose full node is connected to the seed right now. City level "
        "only, from an offline IP-to-city database; no address is stored."
    )
    if not geoip:
        note = ("Nodes whose full node is connected to the seed right now. The "
                "city database is not installed, so only the seed is placed.")
    return {
        "schema": "swarm-map-live/1",
        "updated": server_time_utc,
        "generated_unix": int(time.time()),
        "live": True,
        "nodes_online": online,
        "geoip": geoip,
        "note": note,
        "places": places,
    }


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


def write_atomic(path: Path, data: dict) -> None:
    """Atomic: a reader never sees a half-written file."""
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)
    os.chmod(path, 0o644)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--loop", action="store_true",
                        help="keep regenerating every SWARM_STATUS_INTERVAL seconds")
    args = parser.parse_args()

    interval = int(os.environ.get("SWARM_STATUS_INTERVAL", "30"))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    map_out = args.out.with_name("swarm-map-live.json")

    while True:
        try:
            status = build()
            server_time = status.get("server_time_utc") or utc(time.time())
        except Exception as error:  # never let one bad read stop the loop
            status = {
                "schema": "swarm-network-status/1",
                "server_time_utc": utc(time.time()),
                "healthy": False,
                "error": type(error).__name__,
            }
            server_time = status["server_time_utc"]

        write_atomic(args.out, status)

        # The live map is a second, independent file: whatever state the status
        # read is in, a peer list that answers must still publish a live count,
        # and one that does not answer must say so rather than reuse a stale dot
        # as if it were online.
        try:
            peers = rpc("getpeerinfo")
            map_live = build_map_live(peers, geo_reader(), server_time)
        except Exception as error:
            map_live = {
                "schema": "swarm-map-live/1",
                "updated": server_time,
                "live": False,
                "nodes_online": None,
                "error": type(error).__name__,
                "note": "The seed's peer list could not be read.",
                "places": [dict(SEED_PLACE, count=1)],
            }
        write_atomic(map_out, map_live)

        if not args.loop:
            print(json.dumps(status, indent=2))
            return 0
        sys.stdout.flush()
        time.sleep(interval)


if __name__ == "__main__":
    sys.exit(main())
