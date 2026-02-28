#!/usr/bin/env python3
"""
Configure neuron for TCP concurrent write bug reproduction.

Creates a modbus-tcp south driver with 10 groups (200 tags each, 200ms interval)
and an MQTT north node (QoS 2) connected to EMQX, generating ~3.4KB PUBLISH
messages every 200ms per group.

Usage: python3 setup_neuron.py [EMQX_IP]
  Runs inside the neuron-repro container.
"""

import json
import sys
import time
import urllib.request
import urllib.error

EMQX_IP = sys.argv[1] if len(sys.argv) > 1 else "172.17.0.3"
NEURON_API = "http://localhost:7000/api/v2"

NUM_GROUPS = 10
TAGS_PER_GROUP = 200
GROUP_INTERVAL_MS = 200


def wait_for_neuron(timeout=30):
    """Wait for neuron API to become ready."""
    for _ in range(timeout):
        try:
            req = urllib.request.Request(
                f"{NEURON_API}/login",
                data=json.dumps({"name": "admin", "pass": "0000"}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            urllib.request.urlopen(req, timeout=2)
            return True
        except Exception:
            time.sleep(1)
    return False


def get_token():
    req = urllib.request.Request(
        f"{NEURON_API}/login",
        data=json.dumps({"name": "admin", "pass": "0000"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    resp = json.loads(urllib.request.urlopen(req).read())
    return resp["token"]


def api(method, path, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(
        f"{NEURON_API}/{path}", data=body, headers=headers, method=method
    )
    try:
        return json.loads(urllib.request.urlopen(req).read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())


def generate_tags(group_idx):
    """Generate 200 uint16 holding register tags for a group."""
    tags = []
    base = (group_idx - 1) * TAGS_PER_GROUP
    for t in range(TAGS_PER_GROUP):
        addr = base + t
        tags.append(
            {
                "name": f"tag_g{group_idx}_{t}",
                "address": f"1!3{addr:04d}",
                "attribute": 1,
                "type": 3,
            }
        )
    return tags


def main():
    print(f"Waiting for neuron API...")
    if not wait_for_neuron():
        print("ERROR: neuron API not ready")
        sys.exit(1)

    token = get_token()
    post = lambda path, data: api("POST", path, data, token)

    # Create nodes
    print("Creating nodes...")
    print("  modbus-driver:", post("node", {"name": "modbus-driver", "plugin": "Modbus TCP"}))
    print("  mqtt-north:", post("node", {"name": "mqtt-north", "plugin": "MQTT"}))

    # Configure modbus driver
    print("Configuring modbus driver...")
    print(
        " ",
        post(
            "node/setting",
            {
                "node": "modbus-driver",
                "params": {
                    "connection_mode": 0,
                    "check_header": 0,
                    "device_degrade": 0,
                    "max_retries": 0,
                    "retry_interval": 0,
                    "endianess": 1,
                    "endianess_64": 1,
                    "address_base": 0,
                    "interval": 20,
                    "host": "127.0.0.1",
                    "port": 60502,
                    "timeout": 3000,
                },
            },
        ),
    )

    # Configure MQTT north node (QoS 2)
    print("Configuring MQTT north node...")
    print(
        " ",
        post(
            "node/setting",
            {
                "node": "mqtt-north",
                "params": {
                    "client-id": "neuron-repro-test",
                    "qos": 2,
                    "format": 0,
                    "write-req-topic": "/neuron/mqtt-north/write/req",
                    "write-resp-topic": "/neuron/mqtt-north/write/resp",
                    "offline-cache": False,
                    "cache-sync-interval": 100,
                    "host": EMQX_IP,
                    "port": 1883,
                    "username": "",
                    "password": "",
                    "ssl": False,
                },
            },
        ),
    )

    # Create groups and tags
    for g in range(1, NUM_GROUPS + 1):
        print(f"Creating grp{g}...", end=" ")
        post("group", {"node": "modbus-driver", "group": f"grp{g}", "interval": GROUP_INTERVAL_MS})
        tags = generate_tags(g)
        result = post("tags", {"node": "modbus-driver", "group": f"grp{g}", "tags": tags})
        print(f"tags: {result}")

    # Subscribe MQTT to all groups
    print("Subscribing MQTT north to all groups...")
    for g in range(1, NUM_GROUPS + 1):
        post("subscribe", {"app": "mqtt-north", "driver": "modbus-driver", "group": f"grp{g}"})
    print(f"  subscribed {NUM_GROUPS} groups")

    print("\nDone! neuron is now sending QoS 2 PUBLISH to EMQX.")
    print(f"  EMQX: {EMQX_IP}:1883")
    print(f"  Groups: {NUM_GROUPS} x {TAGS_PER_GROUP} tags @ {GROUP_INTERVAL_MS}ms")
    print(f"  PUBLISH payload: ~3.4KB per group")


if __name__ == "__main__":
    main()
