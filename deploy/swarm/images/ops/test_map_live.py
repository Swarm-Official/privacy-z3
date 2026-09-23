#!/usr/bin/env python3
"""Unit tests for the live-map builders inside status-json.py.

Run with:  python3 -m unittest deploy/swarm/images/ops/test_map_live.py
No network, no Electron, no database file: the IP-to-city reader is a stub, so
the aggregation and the address stripping are what is being tested.
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "swarm_status_json", os.path.join(HERE, "status-json.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeReader:
    """An IP-to-city reader with a fixed, tiny table."""

    def __init__(self, mapping):
        self._mapping = mapping

    def get(self, ip):
        return self._mapping.get(ip)


def _record(city, country, lat, lon):
    return {
        "city": {"names": {"en": city}},
        "country": {"iso_code": country},
        "location": {"latitude": lat, "longitude": lon},
    }


class AddrTest(unittest.TestCase):
    def test_ipv4_addr(self):
        self.assertEqual(mod.ip_from_addr("74.244.193.90:3288"), "74.244.193.90")

    def test_ipv6_addr(self):
        self.assertEqual(mod.ip_from_addr("[2001:db8::1]:8333"), "2001:db8::1")

    def test_no_addr(self):
        self.assertIsNone(mod.ip_from_addr(""))
        self.assertIsNone(mod.ip_from_addr(None))
        self.assertIsNone(mod.ip_from_addr("garbage"))

    def test_addr_without_port(self):
        self.assertEqual(mod.ip_from_addr("1.2.3.4"), "1.2.3.4")


class PlacesTest(unittest.TestCase):
    def setUp(self):
        self.reader = FakeReader({
            "74.244.193.90": _record("Santo Domingo", "DO", 18.46, -69.94),
            "1.2.3.4": _record("Santo Domingo", "DO", 18.46, -69.94),
            "5.5.5.5": _record("Dallas", "US", 32.78, -96.80),
            "9.9.9.9": None,  # unknown to the database -> skipped, never counted
        })

    def test_aggregates_peers_by_city(self):
        peers = [
            {"addr": "74.244.193.90:3288"},
            {"addr": "1.2.3.4:1000"},
            {"addr": "5.5.5.5:1001"},
            {"addr": "9.9.9.9:1002"},
        ]
        places = mod.places_from_peers(peers, self.reader)
        by_name = {p["city"]: p for p in places}
        self.assertEqual(by_name["Santo Domingo"]["count"], 2)
        self.assertEqual(by_name["Santo Domingo"]["country"], "DO")
        self.assertEqual(by_name["Santo Domingo"]["lon"], -69.94)
        self.assertEqual(by_name["Dallas"]["count"], 1)
        self.assertEqual(len(places), 2, "the unresolved peer must not appear")


class MapLiveTest(unittest.TestCase):
    def test_online_count_and_seed(self):
        peers = [{"addr": "74.244.193.90:3288"}, {"addr": "5.5.5.5:1001"}]
        live = mod.build_map_live(peers, FakeReader({
            "74.244.193.90": _record("Santo Domingo", "DO", 18.46, -69.94),
            "5.5.5.5": _record("Dallas", "US", 32.78, -96.80),
        }), "2026-09-23T14:00:00Z")
        self.assertTrue(live["live"])
        self.assertTrue(live["geoip"])
        self.assertEqual(live["nodes_online"], 3)  # seed + two peers
        # Seed is Dallas; the peer in Dallas folds into the SAME place.
        dallas = [p for p in live["places"] if p["city"] == "Dallas"]
        self.assertEqual(len(dallas), 1, "Dallas must be one dot, not two")
        self.assertEqual(dallas[0]["seed"], True)
        self.assertEqual(dallas[0]["count"], 2)  # seed + the Dallas peer
        self.assertEqual(live["places"][0]["city"], "Dallas")
        self.assertEqual(live["places"][1]["city"], "Santo Domingo")

    def test_connected_peer_with_unknown_city_still_counts_as_a_live_node(self):
        # A peer IS connected to the seed (proven by getpeerinfo), so it is a
        # live node even when the database cannot place a city for its address.
        peers = [{"addr": "9.9.9.9:1002"}]
        live = mod.build_map_live(peers, FakeReader({}), "2026-09-23T14:00:00Z")
        self.assertEqual(live["nodes_online"], 2)  # seed + the unplaceable peer
        self.assertEqual(len(live["places"]), 1)    # only the seed is drawn
        self.assertTrue(live["places"][0]["seed"])

    def test_no_peers_is_seed_only(self):
        live = mod.build_map_live([], None, "2026-09-23T14:00:00Z")
        self.assertEqual(live["nodes_online"], 1)
        self.assertFalse(live["geoip"])
        self.assertEqual(len(live["places"]), 1)
        self.assertTrue(live["places"][0]["seed"])


if __name__ == "__main__":
    unittest.main()