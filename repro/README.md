# Reproduce: TCP Concurrent Write Byte Interleaving

Reproduce the `frame_error: invalid_topic, parsed_length=25090` bug caused by
byte interleaving in NanoSDK's `tcp_dowrite()` when `sendmsg()` does a partial
write while multiple aios are queued concurrently.

## Quick Start

```bash
# 1. Start EMQX (if not already running)
docker run -d --name emqx-test emqx/emqx-enterprise:5.10.3

# 2. Set neuron source path and run
export NEURON_DIR=/path/to/neuron
./run.sh
```

`run.sh` will build the Docker image, start the container, configure neuron,
and monitor for 30 seconds. Expected output:

```
=== REPRODUCTION SUCCESSFUL ===
EMQX detected N frame_error(s) caused by byte interleaving.
```

## What the Mock Does

In `posix_tcpconn.c:tcp_dowrite()`, every 50th MQTT PUBLISH packet has its
`sendmsg()` truncated to only send `iov[0]` (the 2-3 byte MQTT fixed header).
This simulates a TCP send buffer full condition that causes partial write.

The PUBLISH body (`iov[1]`, ~3.4KB) is resubmitted by the `send_cb` callback,
but by then a PUBREL packet (from `qsaio`) may have been written into the TCP
stream in between:

```
TCP byte stream (broker receives):
  [PUBLISH header]  →  [PUBREL: 0x62 0x02 ...]  →  [PUBLISH body]
                        ↑ interleaved!
```

The broker reads `0x6202` as topic_length = 25090, which exceeds the packet →
`frame_error: invalid_topic`.

## Environment

| Component | Details |
|-----------|---------|
| neuron-repro | neuron + mock NanoSDK in Docker |
| emqx-test | EMQX Enterprise 5.10.3 |
| Network | tc netem delay 100ms on eth0 |
| TCP wmem | 4096 8192 16384 (small send buffer) |
| Workload | 10 groups × 200 tags, 200ms interval, QoS 2 |

## Log Keywords

| Keyword | Meaning |
|---------|---------|
| `[MOCK] Forcing partial write` | Mock triggered on a PUBLISH |
| `[PROBE] txaio PARTIAL` | MQTT layer detected partial send, resubmitting |
| `[PROBE] *** CONCURRENT WRITE!` | txaio and qsaio overlap detected |
| `frame_error, invalid_topic, parsed_length=25090` | EMQX received corrupted frame |

## Files

- `Dockerfile` — Build neuron + mock NanoSDK image
- `setup_neuron.py` — Configure neuron nodes, groups, tags, subscriptions
- `run.sh` — One-click build, deploy, configure, and verify
