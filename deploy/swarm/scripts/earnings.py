#!/usr/bin/env python3
"""What the project's four addresses hold, read from the node's address index.

    docker run --rm --network <project> -v <project>-auth:/swarm/auth:ro \
        --user 10001:10001 -e SWARM_ZEBRA_RPC=zebra:18232 \
        -v /opt/swarm/verify:/verify:ro <ops image> \
        python3 /verify/earnings.py

Reports, per address, the total received and the balance the node reports, and
splits that balance into spendable and immature itself: every one of these
outputs is a coinbase, and a coinbase cannot be spent until it is 100 blocks
deep. The node's `getaddressbalance` does not make that distinction, so
reporting its number alone would overstate what is actually usable today.

Standard library only. The RPC cookie is read from the shared volume and never
printed.
"""

import base64
import json
import os
import urllib.request

COOKIE = os.environ.get("SWARM_COOKIE_FILE", "/swarm/auth/.cookie")
ADDRESS = os.environ.get("SWARM_ZEBRA_RPC", "zebra:18232")
COIN = 100_000_000
COINBASE_MATURITY = 100

ADDRESSES = [
    ("baseline miner (the server's own payouts)", "t2Li46A4YNFqRDvdKA212w7DtsLkbGMG2xU"),
    ("Core Development", "t2DGVURG5tAyXXSkj85JV5xbvTobYv7H99n"),
    ("Grants & Ecosystem", "t2LVPzRYpZ4QtRRmQMS1zWUmG7TZaYcMjBR"),
    ("Community & Development Reserve", "t2UHhsicXnapNJrfewHqgwXef5HDwCHd7wk"),
]

_auth = None


def rpc(method, params=None):
    global _auth
    if _auth is None:
        token = open(COOKIE, encoding="utf-8").read().strip()
        if token.startswith("__cookie__:"):
            token = token[len("__cookie__:"):]
        _auth = base64.b64encode(f"__cookie__:{token}".encode()).decode()
    body = json.dumps({"jsonrpc": "2.0", "id": "swarm-earnings",
                       "method": method, "params": params or []}).encode()
    request = urllib.request.Request(
        f"http://{ADDRESS}", data=body,
        headers={"content-type": "application/json", "authorization": f"Basic {_auth}"})
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.load(response)
    if payload.get("error"):
        raise SystemExit(f"{method} failed: {payload['error']}")
    return payload["result"]


def coins(zatoshi):
    return f"{zatoshi / COIN:,.8f}"


def main():
    tip = int(rpc("getblockchaininfo")["blocks"])
    mature_below = tip - COINBASE_MATURITY + 1

    print(f"tip height            {tip}")
    print(f"coinbase maturity     {COINBASE_MATURITY} blocks "
          f"(anything mined at height {mature_below} or above is still immature)")
    print()

    total_received = 0
    for label, address in ADDRESSES:
        result = rpc("getaddressbalance", [{"addresses": [address]}])
        balance = int(result.get("balance", 0))
        received = int(result.get("received", balance))
        total_received += received

        # Every output to these addresses is a coinbase, so maturity is decided
        # by the height of the block that paid it. getaddressdeltas is not
        # implemented by this node; the unspent set carries the heights too.
        utxos = rpc("getaddressutxos", [{"addresses": [address]}])
        immature = sum(int(u["satoshis"]) for u in utxos if int(u["height"]) >= mature_below)
        spendable = balance - immature

        print(f"{label}")
        print(f"  {address}")
        print(f"  received   {coins(received):>18} SWM")
        print(f"  balance    {coins(balance):>18} SWM")
        print(f"  spendable  {coins(spendable):>18} SWM   (mature, 100+ blocks deep)")
        print(f"  immature   {coins(immature):>18} SWM   (mined in the last {COINBASE_MATURITY} blocks)")
        print()

    miner_address = ADDRESSES[0][1]
    miner_result = rpc("getaddressbalance", [{"addresses": [miner_address]}])
    miner_received = int(miner_result.get("received", miner_result.get("balance", 0)))
    blocks_by_server = miner_received // (5 * COIN)

    # Era 0: 6.25 per block, every block from height 1.
    subsidy_issued = tip * 625_000_000

    print(f"blocks mined by this server   {blocks_by_server}  "
          f"(at 5.00 SWM each, from the baseline miner's receipts)")
    print(f"total subsidy issued so far   {coins(subsidy_issued)} SWM  "
          f"({tip} blocks x 6.25)")
    print(f"of which to these four        {coins(total_received)} SWM")
    print()
    print("These are testnet coins with no value. The three destination addresses are")
    print("1-of-1 P2SH scripts; spending from them has never been exercised, so treat")
    print("these as received and visible, not as spendable in practice.")


if __name__ == "__main__":
    main()
