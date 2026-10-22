# QMP fault injection (ring 0 replies, cable, resets, ICM mode)

Test-only controls for roadmap M6 ("QMP fault injection"). They make the failures a
connection manager must survive repeatable and scriptable from QMP: a reply that never
comes, one that comes late or twice, a cable pulled at a chosen moment, a host reset
the driver did not ask for, and the firmware CM reporting safe mode.

Every control starts with `x-`, defaults to off, and changes nothing until it is set.
With none of them set the emulator behaves exactly as before (the qtests of every other
suite are unchanged). They complement the NVMe-side harness on the tunnel bridges
([HARNESS.md](HARNESS.md)), which faults individual NVMe commands; this page covers the
CM side: the host interface, the fabric and the firmware CM.

Code: `hw/usb4/usb4-fault.c` (rules, delays, resets, mode), `x-cable` in
`hw/usb4/usb4-device.c`, the RX hook in `usb4_host_rx_frame()` of `hw/usb4/usb4-host.c`.
Tests: `tests/qtest/usb4-fault-test.c` (9 cases).

| Object | Property | Type | Effect |
|---|---|---|---|
| `usb4-host` | `x-reply-faults` | string | Rules on frames queued for RX ring 0, separated by `;` (below). Setting it replaces the rules and resets their counters. A malformed value is refused and the previous rules stay |
| `usb4-host` | `x-reply-fault-state` | string, read | `ruleN=matched/fired ... dropped=N delayed=N pending=N resets=router:N,interface:N icm-mode=N` |
| `usb4-host` | `x-host-reset` | string | Write `router` (host router reset) or `interface` (host interface reset). Reads `router=N interface=N` |
| `usb4-host` | `x-icm-mode` | uint8 | Operating mode reported in bits 11:8 of the outbound mailbox (`0x3990c`, [ICM-PROTOCOL.md](ICM-PROTOCOL.md) §2.3). Default 3 (connection manager mode, as captured); 0 is safe mode. 0-15 |
| `usb4-device` | `x-cable` | bool | `false` pulls the cable: surprise removal of this router and every router below it, the object stays. `true` puts it back |

All are settable on `-device` (start-up state) and at run time with `qom-set`:

```
-device usb4-host,id=u4,...,x-icm-mode=0
-device usb4-device,id=enc0,bus=u4.0,port=1,...,x-cable=off
{"execute":"qom-set","arguments":{"path":"/machine/peripheral/u4",
 "property":"x-reply-faults","value":"pdf=icm-resp code=4 act=delay delay=3000"}}
{"execute":"qom-set","arguments":{"path":"/machine/peripheral/enc0",
 "property":"x-cable","value":false}}
```

Within `-device` a value cannot contain a comma; quote values with spaces for the shell
(`x-reply-faults="pdf=read act=drop"`).

## Reply fault rules (`x-reply-faults`)

Every frame the host interface is about to queue for the guest on RX ring 0 passes the
rules first: control packet responses, notifications and hot plug events from the
fabric (software CM, generic profile and the other USB4 host models), and ICM responses
and events from the emulated firmware CM (Alpine Ridge, Titan Ridge, Ice Lake). Frames
are matched as the fabric or the ICM produced them, before the RX ring checks.

A rule is `key=value` items separated by spaces:

```
pdf=read route=1 nth=3 act=drop+unplug dev=enc0
```

**Match keys** (all optional; a rule with none matches every frame):

| Key | Values |
|---|---|
| `pdf` | `any` (default), `read`, `write`, `notify` (3, errors), `hotplug` (5), `xdomain-req`, `xdomain-resp`, `icm-event` (10), `icm-resp` (12), or a number 0-15 (Spec Table 6-3; ICM-PROTOCOL.md §2.4) |
| `route` | Route String of a control packet (Spec 6.4.1, the CM bit masked off): `0` the host router, `1` the device router on port 1, `0x101` the one behind it. Not with `pdf=icm-*` |
| `code` | ICM packet code, bits 7:0 of the first word (ICM-PROTOCOL.md §3.1). Responses carry the command's code: `3` driver ready, `4` approve, `0xa` get route; events: `3` device connected, `4` device disconnected |
| `nth` | Fire on the Nth match (default 1) |
| `repeat` | `on`: fire on every match from the Nth on. Default `off` fires once |

**Actions** (`act=a+b+...`, required):

| Action | Effect |
|---|---|
| `drop` | The frame is never delivered. Wins over `delay` and `dup` |
| `delay` | Deliver it `delay=MS` ms later (virtual time). Frames behind it are not held: a later reply can overtake it, and one delayed past the guest's timeout arrives stale |
| `dup` | Deliver it now and a second, identical copy `delay=MS` later (default 0: right behind it). The copy is a stale duplicate |
| `unplug` | Pull the cable of `dev=ID` (a `usb4-device` on this host), as `x-cable=off`, from a bottom half right after the frame. With `drop`: the router vanished before it answered |
| `replug` | Put the cable of `dev=ID` back, the same way |
| `host-reset` | Host router reset from a bottom half after the frame (as `x-host-reset=router`) |
| `hi-reset` | Host interface reset from a bottom half after the frame |
| `none` | Nothing (count matches only) |

`delay=MS` (1 to 3600000) is the delay for `delay` and `dup`; `dev=ID` names the device
for `unplug` and `replug`.

Side actions that change the fabric (`unplug`, `replug`, the resets) never run inside
the call that queued the frame: a frame can be queued from inside a TX doorbell write,
and nothing hot-plugs from MMIO context. They run from a bottom half before the next
guest step the main loop serves; with `drop` the guest never sees an answer either way.

Delayed and duplicated frames are not matched again. They survive the guest disabling
and re-enabling ring 0 (a driver restart: that is what makes them stale), and are
discarded by a host interface reset, a host router reset or a device reset, like the
frames waiting in the RX FIFO.

Each firing is traced as `usb4_fault_fire` (virtual ns), each drop, late delivery and
discard as `usb4_fault_deliver`, and emits the QMP event `USB4_REPLY_FAULT` with
`qom-path`, `rule`, `pdf` and `actions`. A test can wait for that event instead of
polling.

## Surprise removal (`x-cable`)

`x-cable=false` is the cable pulled. It does what `device_del` of the `usb4-device`
does, synchronously in the `qom-set`: the router and every router below it are
unplugged, the parent reports the hot unplug (software CM) or the firmware CM sends
device disconnected (ICM), and every tunnel in the subtree goes down with reason
surprise, its access gate closed before the `qom-set` returns
([ARCHITECTURE.md](ARCHITECTURE.md) §4.4; stages 2-4 follow from the slot's bottom half).
Unlike `device_del` the object stays with its configuration, so `x-cable=true` plugs the
same router (same UUID, same NVMe drive) back in, with the routers below it whose own
cable is in. Under a firmware CM the replug is a new connection, announced unapproved.
`x-attached` (read-only) shows whether the router is in the fabric.

`device_del` / `device_add` and the tunnel bridge's `tunnel=surprise` keep working as
before. `tunnel=surprise` takes only the PCIe tunnel down; `x-cable` and `device_del`
remove the router.

### At a chosen moment

- **During enumeration, software CM:** `pdf=read route=1 act=drop+unplug dev=enc0` (add
  `nth=N` to pick the Nth read of that router): the CM's read gets no response and the
  host router reports the hot unplug of its lane adapter.
- **During enumeration, firmware CM:** `pdf=icm-event code=3 act=drop+unplug dev=enc0`:
  the device-connected event is lost and the router is pulled; the guest then gets a
  device-disconnected for a connection it never saw. Without `drop` the guest sees the
  event and the router is gone before it can approve it.
- **During approval:** `pdf=icm-resp code=4 act=drop+unplug dev=enc0`.
- **During NVMe I/O:** hold a command on the tunnel bridge's harness
  (`x-faults="at=fetch op=read act=hold"`, [HARNESS.md](HARNESS.md)), wait until
  `x-release` lists a token, then `x-cable=false`. The command was fetched and never
  completes; the gate is closed in the same `qom-set`. For a tunnel-only surprise at
  the exact command, the harness's own `act=surprise` remains.
- **Rapid plug/unplug:** alternate `x-cable` false/true from a script, or let
  `pdf=icm-event code=3 act=unplug dev=enc0 repeat=on` pull the router each time it is
  announced and a script put it back.

## Host resets (`x-host-reset`)

`router` is a host router reset (Spec 12.6.3.1.2): the host interface registers to
their defaults (rings disabled, interrupt state cleared, the RX FIFO and delayed frames
discarded), the routers to their reset state and, under a firmware CM, the ICM reset (it
comes back with the driver not ready; a new bind is answered). `interface` is a host
interface reset only (Spec 12.6.3.1.3). Both are offered on every profile, Alpine Ridge
included, which has no host router reset register (ICM-PROTOCOL.md R4): the fault is the
controller resetting behind the driver's back, which a driver sees as its rings
reading disabled. The QMP write resets at once (QMP is not MMIO context); the rule
actions `host-reset` and `hi-reset` reset from a bottom half after their frame.

## ICM safe mode (`x-icm-mode`)

The outbound mailbox's operating mode, bits 11:8 (ICM-PROTOCOL.md §2.3). The Linux
client treats 0 (safe mode, NVM upgrade only) by creating a minimal host router and
sending no driver ready, and aborts the bind on any value other than 0 or 3 [inf].
Only the mailbox value changes: the emulated firmware still answers commands, so a
driver that ignores the mode is visible as one that sends driver ready anyway. The
other bits of the register, including the low nibble's D3 marker, are unchanged.

## Exit status (roadmap M6)

Verified by qtest `usb4-fault-test` (2026-10-22): dropped, delayed and duplicated ICM
responses; a dropped control read on the software CM path; a delayed reply discarded by
a host interface reset; QMP and rule-fired host router resets; safe mode in the
mailbox; surprise removal during enumeration on both profiles and during a held NVMe
read under the firmware CM, each with a replug. The guest-level runs (2026-10-22,
[GUEST-EXITS.md](GUEST-EXITS.md)) pass on Linux in both profiles and on Windows 11 in the
generic profile; Windows 11 under the Alpine Ridge firmware CM waits for the Intel driver
(M3 smoke gate).
