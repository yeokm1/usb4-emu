# Alpine Ridge firmware connection manager: host contract

Status: first complete draft, 2026-10-14. Clean-room description (step 1 of the process
`AGENTS.md` required until the project became GPL-2.0-only on 2026-10-15). Implementers of the `tb3-alpine-ridge` profile work from this file and cite
its section numbers. It is written from the P14s Gen 1 capture and from a reading of the
Linux client's behaviour; no client code, structure or header text is reproduced, and
field names are our own.

Every statement carries a tag:

- **[obs]** seen in the capture. A citation follows.
- **[inf]** what the Linux client expects or does, not visible in the capture. A
  hypothesis until a capture confirms it.

## 0. Sources and conventions

Capture: `tests/captures/p14s-gen1/linux-assistOFF_prebootOFF/*.tar.gz`, run
`p14s-linux-20261014-122716-assistOFF_prebootOFF` (Kubuntu 26.04.1 live, kernel
7.0.0-38, legacy/CSM boot, BIOS Thunderbolt Assist off, pre-boot support off, security
level `user`, CalDigit TS3 Plus dock). Citation prefixes, all relative to the run folder:

| Prefix | File |
|---|---|
| `T:n` | `trace-thunderbolt.txt`, line n (thunderbolt tracepoints; timestamps in seconds) |
| `D:n` | `dmesg-live.txt`, line n (monotonic timestamps, about 0.085 s behind the trace clock, judged from paired events) |
| `M:step` | `mmio/0000_05_00.0-<step>.txt`, NHI BAR0 dump at that step |
| `S<n>:path` | `snap-<n>-*/path`, sysfs and debugfs snapshot n |
| `P:path` | `pci/path` (lspci and raw config of the Thunderbolt PCI complex) |

Later captures, used in §9-§12: `win11-assistOFF_prebootOFF/*.zip` (prefix `W:`),
`win98/<Assist>_<Pre-boot>[_NO]/PCIDUMP.TXT` (prefix `P98:`) and
`linux-assistON_prebootON/*.tar.gz` ("Assist-on run"), all in
`tests/captures/p14s-gen1/`. The 2026-10-15 session with a USB4 device (ORICO AAGM2-U4,
ASMedia ASM2464PD) in all four Assist / pre-boot combinations, Linux and Windows 98,
is summarised in §13 and analysed in
[captures/P14S-ORICO-2026-10-15.md](captures/P14S-ORICO-2026-10-15.md) (run prefixes
`R1`-`R4` and `W98:` there).

Steps of the Assist-off Linux run, trace clock: rebind at 123.28, first unplug 151.77, plug 173.98,
approve 174.50, runtime resumes at 193.84 and 250.90, final unplug while runtime
suspended (dmesg 250.78).

Byte order **[inf]**: every ring 0 frame is a sequence of 32-bit words sent most
significant byte first, followed by a 4-byte trailer. All words below are given as
numeric values the way the trace prints them; fields are bit ranges within those values.
Byte strings (UUIDs, names, DROM) are laid into words little-endian first, i.e. byte k of
a string is bits `8*(k%4)+7 .. 8*(k%4)` of word `k/4`, and that word is then sent most
significant byte first. Example: the ICM header word `0x0100e203` goes on the wire as
`01 00 e2 03`.

## 1. Identity and PCI topology

| Item | Value | Tag |
|---|---|---|
| Controller | Intel JHL6240 Alpine Ridge LP (2016), one Thunderbolt port, two lanes | [obs] `P:lspci-nn.txt` |
| NHI | `8086:15bf` rev 01, class `0x088000` (system peripheral), subsystem `17aa:22b0` | [obs] `P:tb-complex/0000_05_00.0/lspci.txt` |
| NHI BARs | BAR0 256 KiB 32-bit non-prefetchable (registers); BAR1 4 KiB (MSI-X table at 0, PBA at 0xfa0) | [obs] same |
| NHI capabilities | PM at 0x80, MSI at 0x88 (1 vector, 64-bit), PCIe endpoint at 0xc0, MSI-X at 0xa0 (16 vectors), then DSN, AER, VC, power budgeting, vendor-specific (ID 0x1234), LTR | [obs] same |
| PCIe switch | upstream port 03:00.0 `8086:15c0`; downstream ports 04:00.0 (to NHI, bus 05), 04:01.0 (tunnel, buses 06-2a, hot-plug and surprise capable slot), 04:02.0 (to xHCI, bus 2b); all subsystem `17aa:22b0`, all with a vendor-specific extended capability at 0x500 (ID 0x1234) | [obs] `P:tb-complex/*/lspci.txt` |
| Integrated xHCI | `8086:15c1`, class `0x0c0330`, at 2b:00.0 | [obs] same |
| Root port above | PCH root port 00:1c.4 `8086:02bc`, bus range 03-2b | [obs] same |

The Linux client binds the NHI by vendor and device ID alone; the class code plays no part
[inf]. The Intel Windows INF does match on the class code (`CC_0880`) [obs] §10.1. It selects the Alpine Ridge message set from the device ID (`0x15bf` and the other
Alpine Ridge NHI IDs) [inf].

## 2. Host interface registers (NHI BAR0)

The ring register layout is the common NHI layout (USB4 Spec §12.6 has the generic form;
the FreeBSD `nhi_reg.h` cross-check uses the same offsets). Only Alpine Ridge specific
values and semantics are listed here.

### 2.1 Values seen with firmware running

Identical at all seven dumps unless noted [obs] `M:1-initial` to `M:7-unplugged-again`.

| Offset | Register | Value | Notes |
|---|---|---|---|
| 0x39640 | host capabilities | `0x0000000c` | bits 9:0 = 12 rings (dmesg "total paths: 12", `D:1501`). Bits 23:16, the interface version, read 0, so the client skips the host-router reset handshake [inf]. |
| 0x39864 | DMA misc | `0x01000016` | bit 2 is the Intel interrupt auto-clear enable, set by the client because it uses MSI-X (§2.5). Bits 1, 4 and 24 are set and unexplained. The value survives driver unbind (`M:2-unbound`). |
| 0x39900 | inbound mailbox data | `0x00000000` | |
| 0x39904 | inbound mailbox command | `0x00000007` or `0x00000023` | last command code stays in bits 7:0 after completion; request and error bits clear (§2.3) |
| 0x39908 | (unnamed) | `0x00000000` | |
| 0x3990c | outbound mailbox | `0x800003f5` | bits 11:8 = 3, the connection-manager operating mode. Bit 31 and the low byte `0xf5` are set and unexplained. |
| 0x39944 | firmware status | `0x800001a1` | bit 31 NVM authentication done, bit 0 ICM enabled; bits 5, 7, 8 set and unexplained; bit 30 (CIO reset request), bits 1 and 2 clear |
| 0x38200 | ring interrupt enable 0 | `0x00001001` with driver bound, `0` unbound | bit 0 = TX ring 0, bit 12 = RX ring 0 (RX bits start at the ring count) |
| 0x38c00..0x38c3c | interrupt throttling, 16 entries | `0x000001f4` each | same unbound, so this is the reset value |
| 0x38c40.. | interrupt vector allocation | `0`, `0x00010000`, `0`... | RX ring 0 (index 12) on MSI-X vector 1, TX ring 0 on vector 0 |
| 0x19800 / 0x29800 | TX / RX ring 0 options | `0xc0000000` | ring enable (bit 31) and raw mode (bit 30); `0` when unbound |
| 0x29804 | RX ring 0 PDF masks | `0xffffffff` | accept every frame type |
| 0x0800c | RX ring 0 size | `0x0100000a` | 10 descriptors, 256-byte buffers |
| 0x0000c | TX ring 0 size | `0x0000000a` | 10 descriptors |

Not captured: the ring interrupt status block at 0x37800 (the capture tool skipped it
because reads clear it), the mask set/clear registers at 0x38208, the host reset register
0x39898.

### 2.2 Firmware status register (0x39944)

| Bit | Meaning | Client use |
|---|---|---|
| 0 | ICM enabled | Read at probe. Set: firmware CM path is taken. Clear: the client gives up on the firmware CM unless the user asked it to start the firmware (§2.7), then falls back to its software CM [inf]. |
| 1 | invert ICM enable | written only on the firmware start path [inf] |
| 2 | ICM CPU enable | written only on the firmware start path [inf] |
| 30 | CIO reset request | written only on the firmware start path [inf] |
| 31 | NVM authentication done | Polled before reading the operating mode: up to 60 reads 50 ms apart; if never set the bind fails [inf]. |

Observed value `0x800001a1` at every step, including while the driver was unbound [obs]
`M:*`. The emulator resets to this value.

### 2.3 NHI mailbox

Registers: inbound data (0x39900), inbound command (0x39904), outbound (0x3990c).

Inbound command word: bits 7:0 command code, bit 30 error, bit 31 request.

Handshake [inf]: the client writes the data word, then reads the command register, clears
bits 7:0 and bit 30, sets bit 31 and the code, and writes it back. It polls about every
10-20 µs for up to 500 ms until bit 31 reads 0. Bit 31 still set is a timeout; bit 30
set is a failure. After completion the code stays in bits 7:0 [obs]: `M:3-after-rebind`
holds `0x23`, `M:1-initial` and `M:2-unbound` hold `0x07`.

Operating mode: bits 11:8 of the outbound register. Values the client distinguishes:
0 safe mode (only NVM upgrade possible), 1 authentication mode, 2 endpoint mode, 3
connection-manager mode [inf]. Observed 3 [obs]. Safe mode makes the client create a
minimal host router and send no driver-ready; any value other than 0 or 3 aborts the bind
[inf].

| Code | Command | Data | When the Alpine Ridge client sends it | Evidence |
|---|---|---|---|---|
| 0x05 | save devices | 0 | system suspend, before 0x07 | [inf] |
| 0x06 | disconnect PCIe paths | 0 | teardown of all PCIe tunnels by the client (host NVM upgrade path) | [inf] |
| 0x07 | driver unloads | 0 | driver unbind, system suspend, runtime suspend | [obs] `M:2-unbound` after unbind; `M:1-initial` and `M:5-plugged` after runtime suspends |
| 0x10 / 0x11 | disconnect port A / B paths | 1, then 2 | tearing down a host-to-host DMA tunnel | [inf], out of scope |
| 0x23 | allow all devices | 0 | every bind, right after the mode check shows CM mode, before driver-ready | [obs] `M:3-after-rebind` |

Effect of "driver unloads" [obs]: tunnels and device approval survive it. After the
runtime suspend before `T:34155` the dock was re-announced as approved (`T:34163`,
approved bit set) and no PCIe link-down was logged. A device unplugged while the driver
was unloaded produced no event (§6.6).

### 2.4 Ring 0

Ring 0 TX and RX carry both control packets and ICM packets, in raw mode, so the RX
buffer receives the 4-byte trailer too [obs] options `0xc0000000`; [inf] raw semantics.
Frame type values (the PDF field in the descriptor) [inf]: config read 1, config write 2,
error 3, ICM event 10, ICM command 11, ICM response 12. The largest observed frame is the
device-connected event, 61 words plus trailer = 248 bytes, inside the 256-byte buffer
[obs] `T:9`.

### 2.5 Interrupts

- The client asks for 6 to 16 MSI-X vectors first and falls back to one MSI vector
  [inf]. On the P14s it got MSI-X: MSI-X enabled with 16 entries, MSI disabled [obs]
  `P:tb-complex/0000_05_00.0/lspci.txt`; vector allocation as in §2.1 [obs].
- With MSI-X, for each ring it enables, the client sets the Intel auto-clear bit (DMA
  misc bit 2), programs that ring's vector in the vector allocation registers (4 bits per
  ring index, 8 per register) and the throttle entry for the vector, then sets the
  ring's bit in the enable register at 0x38200 [inf]; the end state is [obs] §2.1.
- With the auto-clear bit set, the hardware clears a ring's status bit when it sends that
  ring's MSI-X message; with it clear, reading a status register clears the bits read
  [inf]. The client never writes the status-clear register on Intel hardware and masks a
  ring by read-modify-write of the enable register [inf].
- With a single MSI, the interrupt handler reads the three status bitfields starting at
  0x37800 (TX, RX, RX overflow, each one bit per ring, packed contiguously) and services
  every set bit; this relies on read-to-clear [inf].
- No INTx use by Linux [inf]. INTx pin A is wired [obs] lspci "pin A routed to IRQ 16".

### 2.6 Host reset

Not used on Alpine Ridge: the capabilities register reports interface version 0 [obs]
§2.1, below the version from which the client issues a host-router reset [inf].

### 2.7 Starting stopped firmware, and the upstream-port vendor capability

Not exercised in the capture: the firmware was running throughout [obs] §2.1. The Linux
client only takes this path when the ICM enable bit is clear and the user passed an
explicit opt-in [inf]. For the record, what it does then [inf]:

1. Locates the PCIe upstream port of the controller's switch (device IDs of the Alpine
   Ridge and Titan Ridge bridges, here `8086:15c0`) and its first PCIe vendor-specific
   extended capability (here at 0x500 [obs]).
2. That capability holds a PCIe-to-fabric config mailbox: command word at +0x30 (bits
   12:0 dword index, bits 18:13 adapter, bits 20:19 config space, bit 21 write, bit 30
   start, bit 31 timeout), write data at +0x34, read data at +0x38. The client sets
   start, polls every 50 ms for up to 5 s until start clears, and treats timeout set as
   failure.
3. Sets the CIO reset request bit in firmware status, then the invert and CPU enable
   bits, then writes bit 9 of router config dword 0x50 of the host router through the
   mailbox; then waits up to 3 s (10 x 300 ms) for NVM authentication done.
4. For each pair of lane adapters (1/2 and 3/4) whose port config dword 0x37 shows link
   state "up" in bits 29:26, sets and then clears the link-disable bit 14 in that dword.

The emulator does not implement this path (`ARCHITECTURE.md` §1 non-goals). It must
still keep the firmware status reset value so the client never tries. No Linux "force
power" mechanism exists for Alpine Ridge; Windows may use platform ACPI methods for it,
see §9.

## 3. ICM framing on ring 0

- Command frames from the host have frame type 11, responses type 12, unsolicited
  events type 10 [inf]; observed as `ICM_CMD`, `ICM_RESP`, `ICM_EVENT` in the trace [obs].
- The host appends a CRC-32C trailer to commands [inf]. For responses and events the
  client strips the last 4 bytes without checking them [inf]. The emulator sends a
  correct CRC-32C trailer anyway (same algorithm as control packets, Spec §6).
- ICM payloads carry no route string or config address; they start directly with the
  ICM header word [obs] e.g. `T:1` `data=[0x00000003]`.
- A response is matched to the outstanding command by frame type 12 and an equal code
  in the header [inf]. Only one ICM command is outstanding at a time [inf]. Config
  packets can interleave with an outstanding ICM command [inf].
- Response length: the client copies its fixed structure size from the frame, so the
  emulator must send at least the sizes in §4; the observed lengths are given there.
- Timeouts [inf]: 5 s per command, retried up to 3 more times on timeout; approve uses
  10 s. A command never answered makes the bind or the sysfs write fail.
- Events are not acknowledged [obs]: nothing is sent in reply to `T:9`, `T:21087`,
  `T:27886`, `T:34163` other than the client's own follow-up commands.

### 3.1 ICM header word (word 0 of every ICM payload)

| Bits | Field |
|---|---|
| 7:0 | code (command or event) |
| 15:8 | flags (per message; bit 0 means error in every response) |
| 23:16 | packet index, starting at 0 |
| 31:24 | packet count |

Multi-packet rule [inf]: a response made of several frames carries the same code in each;
the client places frame i at offset i times the per-frame size and completes when index
equals count minus 1. On Alpine Ridge every message the client uses is single-packet
(the 14-packet topology query is Falcon Ridge only). Observed: requests from the host have
index 0 and count 0 (`0x00000003` [obs] `T:1`); every response and event has index 0 and
count 1 [obs] all 34 ICM frames.

## 4. Alpine Ridge ICM message set

Codes:

| Code | Command | Alpine Ridge client | Observed |
|---|---|---|---|
| 0x01 | topology query | not used (Falcon Ridge only) | no |
| 0x03 | driver ready | every bind and every resume | 4 times |
| 0x04 | approve device | user writes `authorized=1` | once |
| 0x05 | challenge device | security level `secure` only | no |
| 0x06 | add device key | security level `secure` only | no |
| 0x0a | get route | after each new device-connected event | twice |
| 0x10 | approve host-to-host paths | inter-domain only | no |
| 0x18 | boot ACL read / write | sysfs `boot_acl` read or write (boltd, capture tool) | 8 times |
| 0x11, 0x20 | inter-domain disconnect, USB4 router operation proxy | never on Alpine Ridge | no |

| Code | Event | Observed |
|---|---|---|
| 0x03 | device connected | 3 |
| 0x04 | device disconnected | 1 |
| 0x06, 0x07 | host-to-host link connected / disconnected | no (out of scope) |
| 0x08 | DisplayPort configuration changed | no; the client only forwards a notification [inf] |
| 0x0a | RTD3 veto | no; Ice Lake and later only [inf] |

### 4.1 Driver ready (0x03)

Request: 1 word, header only, flags 0 [obs] `T:1`.

Response: 2 words [obs] `T:2`, `T:34156`, `T:62128`, always `0x0100e203 0x28010b60`.

| Word | Bits | Field | Observed | Client use |
|---|---|---|---|---|
| 0 | 15:8 | flags | `0xe2` | bit 6: controller supports runtime D3 (RTD3). Bits 1, 5, 7 set, meaning unknown, ignored [inf]. |
| 1 | 7:0 | ROM version | `0x60` | ignored [inf] |
| 1 | 15:8 | RAM version | `0x0b` | ignored [inf] |
| 1 | 19:16 | security level | 1 (`user`) | domain security level [obs] `S6:sys-bus-thunderbolt/domain0/security` = `user` |
| 1 | 27:23 | boot ACL entry count | 16 | used only if bit 29 is set; above 16 the client disables the feature [inf] |
| 1 | 29 | boot ACL supported | 1 | |

Security level values [inf]: 0 none, 1 user, 2 secure, 3 DisplayPort only, 4 USB only,
5 no PCIe. Alpine Ridge returns no protocol version; the client treats it as 0 [inf].

Consequences of these values [obs]: the domain exposes `boot_acl` with 16 slots (boltd
reported `bootacl: 2/16`, `S6:boltctl.txt`), and runtime PM is enabled, which produced two
runtime suspend/resume cycles in a 2.5-minute run (§6.5).

After the response the client polls the host router: config read of router space dword 0,
1 dword, 100 ms timeout, up to 50 tries 50 ms apart; it proceeds only once one succeeds
[inf]. The real firmware leaves these reads unanswered while it is still announcing
attached devices (§6.2) [obs].

### 4.2 Get route (0x0a)

Translates an event's link and depth into the device router's route string.

| Word | Request | Response |
|---|---|---|
| 0 | header, code 0x0a, flags 0 | header, flags: bit 0 error |
| 1 | bits 15:0 zero; bits 31:16 link info (§4.4) | echo of request word 1 |
| 2 | | route string bits 63:32 |
| 3 | | route string bits 31:0 |

Observed [obs] `T:833`-`T:834`, `T:27887`-`T:27888`: request `0x0000000a 0x00110000`
(link 1, depth 1), response `0x0100000a 0x00110000 0x00000000 0x00000001` within 3-10 ms.
The route string of a depth-1 device is the host lane adapter number it hangs off.

### 4.3 Approve device (0x04)

| Word | Field |
|---|---|
| 0 | header, code 0x04 |
| 1-4 | device UUID, as received in the device-connected event |
| 5 | bits 7:0 connection key; bits 15:8 connection id; bits 31:16 zero |

Observed request [obs] `T:34153` at 174.497:
`0x00000004 0xa0211100 0x003d0efc 0xffffffff 0xffffffff 0x00000610` (key 0x10, id 6).
Response [obs] `T:34154` at 174.855 (358 ms later): the same six words with header
`0x01000004` (flags 0). A response with flags bit 0 set means tunnel creation failed and
the sysfs write returns an I/O error [inf].

The firmware creates the PCIe tunnel while processing the request: the host tunnel port
04:01.0 reported card present and link up at dmesg 174.475 (trace clock about 174.56),
after the request and about 0.3 s before the response [obs] `D:1689`-`D:1690`.

### 4.4 Device connected (event 0x03)

61 words [obs] `T:9`, `T:27886`, `T:34163`.

| Word | Bits | Field | Observed |
|---|---|---|---|
| 0 | 15:8 | flags: bits 4:3 security level, bit 5 dual lane, bit 7 20 Gb/s lane speed (else 10) | `0xb1` every time: dual lane, 20 Gb/s, level field 2, bit 0 also set |
| 1-4 | | device UUID (16 bytes, byte order per §0) | `0xa0211100 0x003d0efc 0xffffffff 0xffffffff` |
| 5 | 7:0 | connection key | `0x10` every time |
| 5 | 15:8 | connection id | 5, 6, 7 on successive announcements |
| 5 | 18:16 | link: host lane adapter number the device is reached through | 1 |
| 5 | 23:20 | depth | 1 |
| 5 | 24 | approved: PCIe tunnel already established | 1 at `T:9` and `T:34163`, 0 at `T:27886` |
| 5 | 25 | rejected: topology limit exceeded, the client ignores the device | 0 |
| 5 | 26 | boot: device was attached and approved before the OS | 0 |
| 5 | 27 | unknown | 1 every time |
| 6-60 | | endpoint name block, 220 bytes (below) | |

Link info is the same 16-bit value as in get route and device disconnected: bits 2:0
link, 7:4 depth, 8 approved, 9 rejected, 10 boot; observed `0x0911` (approved) and
`0x0811` (not approved).

Endpoint name block: a list of entries, each `length, type, data...` where length counts
the 2 header bytes; a zero length ends the list. Observed entries [obs] `T:9`:

| Type | Content | Observed |
|---|---|---|
| 0x01 | vendor name, NUL-terminated ASCII | "CalDigit, Inc." (length 0x11) |
| 0x02 | model name, NUL-terminated ASCII | "TS3 Plus" (length 0x0b) |
| 0x10 | Intel vendor-specific: vendor ID (16 bits), model ID (16 bits), one byte of unknown meaning, flags byte (bit 0 = device supports RTD3) | `3d 00 11 00 11 01` (length 0x08): vendor 0x3d, model 0x11, flags 0x01 |
| 0x12 | unknown, no data | length 0x02 |

The rest of the block is zero. Linux uses only the RTD3 flag from it; vendor and model
names shown in sysfs come from the device DROM [inf], and match it [obs] `S6:sys-bus-thunderbolt/0-1/vendor_name`.

Identity consistency [obs]: the event UUID's first 8 bytes equal the DROM UID
(`0x003d0efca0211100`, `D:1556`), the last 8 bytes are all ones, and sysfs shows
`unique_id` `001121a0-fc0e-3d00-ffff-ffffffffffff`.

Security level in the event flags reads 2 although the domain level is 1 [obs]. The
client stores it per device and uses it only for key handling [inf]. The emulator copies
the observed flags byte.

Client handling [inf]: a known UUID at the same link, depth and approval state only
refreshes connection id, key and route (no config reads, observed after `T:34163`);
otherwise it removes any stale router at that link and depth, sends get route, reads the
new router's config space (§5) and registers it.

### 4.5 Device disconnected (event 0x04)

2 words [obs] `T:21087`: `0x01000004 0x00110000`.

| Word | Bits | Field |
|---|---|---|
| 0 | | header, flags 0 |
| 1 | 15:0 | zero |
| 1 | 31:16 | link info, link and depth only |

The client removes the router found at that link and depth, warning if none [inf].

### 4.6 Boot ACL (0x18)

| Word | Field |
|---|---|
| 0 | header, code 0x18; flags bit 7 = write |
| 1-32 | 16 entries of 2 words: UUID bytes 0-3, UUID bytes 4-7. Bytes 8-15 of every listed UUID are implicitly all ones. `0xffffffff 0xffffffff` is an empty slot. |

- Read [obs] `T:7099`-`T:7100`: request is 33 words with zero entries; response 33
  words, flags 0, with the stored list: `0xa0211100 0x003d0efc` (the dock),
  `0x28f88500 0x8086d8df` (another device), 14 empty slots. Round trip 11 ms.
- Write [obs] `T:7101`-`T:7102`: request header `0x00008018` plus the full list (boltd
  wrote back the same two entries); response 33 words, header `0x01008018` (flags still
  `0x80`, error clear), all entries zero. Round trip 125 ms.

The list is stored in controller NVM and persists across boots [obs] it was already
populated at the first read. The firmware's use of it (pre-boot auto-connect) is not
exercised in this run because pre-boot support was off [obs] capture settings.

### 4.7 Key and challenge (0x06, 0x05)

Not used at security level `user` [obs]. Layouts [inf]: request words 0-5 as for approve,
then 8 words of key (add key) or challenge. The challenge response repeats words 0-5, the
8 challenge words, then 8 response words; flags bit 0 means rejected, bit 1 means no key
stored.

### 4.8 Errors

The only error signal is bit 0 of the response flags [inf]. The capture has no error
responses [obs]. Behaviour for unknown codes was not observed; the emulator answers with
the request header and bit 0 set (§8 R15).

### 4.9 How Alpine Ridge differs from Titan Ridge (both [inf])

The Linux client has separate handling for the two generations. Titan Ridge is a later,
uncaptured variant. It is modelled, from the Linux client alone, as
`profile=tb3-titan-ridge`; its contract (requirements T1-T12) is
[ICM-TITAN-RIDGE.md](ICM-TITAN-RIDGE.md), which supersedes this table for details.

| Aspect | Alpine Ridge | Titan Ridge |
|---|---|---|
| Driver-ready response | 2 words; info in bits 31:16 of word 1: level in bits 3:0, ACL count bits 11:7, explicit "ACL supported" bit 13; ROM and RAM version bytes; no protocol version | 4 words; info 16 bits after a reserved half-word: level in bits 2:0, protocol version bits 6:4, ACL count bits 12:7; plus NVM version and device ID words |
| Device addressing in events | link and depth; the client must ask for the route with get route (0x0a) | route string carried in the event; no get route |
| Connection key | present in events and approve | absent |
| Approve and key requests | UUID, key, id | UUID, route string, id |
| Device disconnected | link info | route string |
| Inter-domain disconnect | NHI mailbox commands 0x10/0x11 | ICM message 0x11 with stages |
| USB4 router operation proxy | none | present if protocol version is 3 or more |
| Firmware restart reset | fabric dword 0x50 bit 9 via the upstream-port mailbox | a different sequence |

Shared: header, codes, boot ACL format, mailbox commands, RTD3 flag at bit 6 of the
driver-ready flags, firmware status and operating-mode handling.

## 5. Config space traffic the client generates (tb3 dialect)

Config packets follow Spec §6 (route string, offset, length, adapter, space, sequence
number, CRC-32C). Facts specific to these routers:

- Replies carry the receiving router's upstream adapter in the adapter field: 3 (the NHI
  adapter) for the host router, 1 for the dock [obs] e.g. `T:11`, `T:835`. The client does
  not check that field [inf].
- Reads of unimplemented router-space offsets return an error packet with code 2 (invalid
  config space) [obs] e.g. debugfs reads of router dwords from 0x1b3 on route 0 and route
  1. The client itself never reads there [obs].
- The client only ever writes two registers: the EEPROM control dword (router 0x2c) on
  both routers and the DMA-port inbound mailbox (adapter 3 / 5, dword 0x4f) [obs] all 4181
  write packets in the trace. That holds for Thunderbolt 3 routers. For a USB4 device
  router the client also writes ROUTER_CS_25 and ROUTER_CS_26 to run router operations
  (DROM Read, NVM Sector Size) through the firmware [obs] §13.3.

Full register images of both routers per step are in `S<n>:debugfs-thunderbolt/0-0/regs`,
`0-1/regs` and `*/port<n>/regs`; the tables below give what the client reads.

### 5.1 Host router, route 0 (Alpine Ridge LP, `8086:15c0`)

Router header [obs] `T:15`: `0x15c08086 0x01014305 0x00000000 0x80000000 0x020000fe`:
vendor 0x8086, device 0x15c0; first capability at 0x05, upstream adapter 3, highest
adapter 5, depth 0, revision 1; route 0; configured bit 31; plug-events delay 0xfe,
Thunderbolt version byte 2. The device ID must be one the client maps to generation 3
(Alpine Ridge or Titan Ridge bridge IDs) [inf]; the sysfs `generation` is 3 [obs].

Router capability chain [obs] `T:17`-`T:97`, `S6:debugfs-thunderbolt/0-0/regs`:

| Dword | Header | Capability |
|---|---|---|
| 0x05 | `0x03200320` | TMU (id 3), next 0x20 |
| 0x20 | `0x07000528` | vendor-specific (id 5), sub-id 0, length 7, next 0x28 |
| 0x28 | `0x35010563` | vendor-specific sub-id 1, plug events and EEPROM, length 0x35, next 0x63 |
| 0x63 | `0x08020579` | sub-id 2, next 0x79 |
| 0x79 | `0x320305ac` | sub-id 3, next 0xac |
| 0xac | `0x220405cf` | sub-id 4, next 0xcf |
| 0xcf | `0x110505ff` | sub-id 5, next 0xff |
| 0xff | `0x00060500` | sub-id 6, link controller, long header, end of chain |

The client walks this chain repeatedly by reading each header (1 dword, then 2 dwords) to
find sub-ids 1 and 6 [obs].

Plug-events capability, 13 dwords from 0x28 [obs] `T:103`:
`35010563 00005281 00000000 00ff0000 0002018a e4454321 00000000 00000000 93563562
00007ffe 00000000 00000000 00000210`. Dword +4 (0x2c) is the EEPROM control register
(§5.4), dword +12 (0x34) the DROM offset in the EEPROM, 0x210.

Link controller: host UUID read from 4 dwords at 0xff+3 = 0x102 [obs] `T:97`:
`0x000001cd 0x88808200 0x8a6159a0 0x0220a110`, shown in sysfs as
`cd010000-0082-8088-a059-618a10a12002` [obs] `S6:.../0-0/unique_id`. Only the host's is
read; a device router's UUID comes from the event [obs] no reads at 0xff/0x102 on route 1.

Adapters [obs] `T:743`-`T:815`:

| Adapter | Type (port dword 2) | Port header dwords 0-5 | Capabilities read |
|---|---|---|---|
| 1 | lane (`0x01000001`) | `15c08086 0108100a 01000001 80100078 07800000 0000780f` | 0x0a `00000336`, 0x36 `003c013e` (PHY), 0x3e `10000500` |
| 2 | lane | `15c08086 0108100a 01000001 80200000 00000000 0000780f` | as adapter 1 |
| 3 | NHI (`0x01000002`) | `15c08086 0108103e 01000002 80300010 01000000 0000580b` | 0x3e `13010552` (DMA port), 0x52 `04000500` |
| 4 | PCIe down (`0x01100101`) | `15c08086 01080239 01100101 80400008 00800000 00004008` | 0x39 `c6210400` |
| 5 | DP in (`0x010e0101`) | `15c08086 01080239 010e0101 80500010 01000000 00004809` | 0x39 `0000044f` |

Adapter 3 is both the router's upstream adapter and an NHI-typed DMA port [obs].

### 5.2 DMA port (host adapter 3, dock adapter 5)

Probe [obs] `T:99`, `T:919`-`T:921`: the client reads port dword 2 of adapters 3, 5, 7 in
that order and takes the first whose bits 23:0 equal 2 (NHI). Host: adapter 3. Dock:
adapter 3 is a lane adapter, adapter 5 is NHI-typed (`0x01000002`) although the DROM
disables it.

Mailbox at fixed port dwords [obs] `T:105`-`T:127`, `T:817`-`T:831`, `T:7081`-`T:7097`:

| Dword | Function |
|---|---|
| 0x3f-0x4e | data window, 16 dwords |
| 0x4f | inbound: bits 31:28 command (2 = flash read), bits 27:24 dword count (0 means 16), bits 23:2 dword address in flash, bit 0 request |
| 0x50 | outbound: bit 29 response valid, bits 7:4 echo of the command, bits 3:0 status (0 done, 1 auth error, 2 access error) |

The client writes the inbound word with bit 0 set, polls it until bit 0 reads 0 (the dock
took one extra poll, `T:7083`), reads the outbound word (`0x20000020`), then reads the
data window. Commands seen: flash read only. Flash locations read [obs]:

| Router | Address | Words | Value | Purpose [inf] |
|---|---|---|---|---|
| host | 0x21c | 1 | `0x004801d6` | DROM length (bytes 0x21e-0x21f = 0x48) |
| host | 0x210 | 16 + 6 | DROM copy, `S6:debugfs-thunderbolt/0-0/drom` | host DROM |
| host | 0x44 | 2 | `0xaaaa2b2d 0x04282806` | flash size code at byte 0x45 |
| host | 0x08 | 1 | `0x00230000` | NVM version 23.0 |
| dock | 0x44 | 2 | `0xaaaa2b2d 0x0428a804` | flash size |
| dock | 0x08 | 1 | `0x10440000` | NVM version 44.0 |

Before using the port the client also reads the outbound word once to check the result of
any previous flash authentication; status 0 means none pending [inf], observed
`0x20000020` [obs] `T:101`.

When no adapter among 3, 5, 7 is NHI-typed the client skips NVM support for that router
without error, and for the host falls back to reading only the UID through the EEPROM
[inf]. This is the deviation `ARCHITECTURE.md` §4.2 chooses by default.

### 5.3 Device router, route 1 (CalDigit TS3 Plus, `8086:15d3`)

The dock's router is an Alpine Ridge (C, 4-channel) device router [obs]. Router header
[obs] `T:837`: `0x15d38086 0x0612c105 0x00000001 0x80000000 0x020000fe`: upstream adapter
1, highest adapter 11, depth 1, revision 6, route 1. Capability chain identical in layout
to the host's (0x05, 0x20, 0x28, 0x63, 0x79, 0xac, 0xcf, 0xff) [obs] `T:839`-`T:917`.
Plug-events capability [obs] `T:925`: `35010563 00005e01 00000000 ffff0000 0002218e
e4454321 00000000 0000000f 93633632 00007ffe 00000000 00000000 00000210`.

Adapters [obs] `T:6953`-`T:7079`: 1-4 lane (dual-port device; only 1 is linked), 5 NHI
type (DMA port, disabled by DROM), 6 PCIe up (`0x01100102`), 7 PCIe down, 8 and 11 DP out
(`0x010e0102`), 9 and 10 disabled by DROM and not read. Lane adapters have the same
chain as the host's (0x0a, 0x36, 0x3e); PCIe adapters a single capability at 0x39
(up `0xc6210400`, down `0x01260400`); DP adapters 0x0a `0x00000339` then 0x39 `0x0000044f`.

Device DROM: 0x70 bytes read by EEPROM bit-bang from EEPROM offset 0x210 (§5.4); content
in `S6:debugfs-thunderbolt/0-1/drom`: UID `0x003d0efca0211100`, vendor 0x3d "CalDigit,
Inc.", device 0x11 "TS3 Plus" [obs] `D:1555`-`D:1556`.

### 5.4 EEPROM bit-bang protocol (router dword 0x2c on both routers)

Control dword bits: 0 clock, 1 chip select (0 = selected), 2 data to EEPROM, 3 data from
EEPROM, 4 bit-bang enable, 5 not-present, 7 present; bits 31:8 preserved by the client
[inf]. Idle values: host `0x0002018a`, dock `0x0002218e` [obs] `T:103`, `T:925`.

Before each transfer the client reads 13 dwords from the plug-events capability, needs
present = 1 and not-present = 0, and takes the DROM offset from dword +12 [inf]; observed
re-read before every transfer [obs] `T:129`, `T:1189`.

Transfer [obs, decoded from `T:131`-`T:740` and `T:925`-`T:6952`]:

1. Enable: write with enable = 1, then write with chip select = 0.
2. Send bytes MSB first. Per bit: write with the data bit (clock 0), write with clock 1,
   write with clock 0.
3. Send `0x03` (read), then the 16-bit address high byte, low byte. The address is the
   DROM offset plus the byte offset wanted.
4. Receive bytes MSB first. Per bit: write with clock 1, read the control dword and take
   bit 3, write with clock 0.
5. Disable: write with chip select = 1, then write with enable = 0.

So the EEPROM behaves as a 25-series SPI EEPROM with a read command and a 16-bit address.
Observed transfers:

| Router | Address | Bytes | Data | Purpose |
|---|---|---|---|---|
| host | 0x210 | 9 | `49 00 88 50 98 15 a6 09 01` | CRC-8 then 8-byte UID `0x0109a61598508800` (dmesg "0: uid") |
| dock | 0x21e | 2 | `63 00` | DROM data length 0x63, total 0x70 |
| dock | 0x210 | 112 | full DROM | parsed for names and adapter entries |

The host UID read through the EEPROM differs from the placeholder UID in the NVM DROM copy
(`61 00 00 00 00 00 00 09 01`) [obs]; the client keeps the EEPROM one [inf]. Cost: the
dock DROM took 1976 writes and about 390 ms [obs] `T:925`-`T:6952`.

### 5.5 Read order after a device-connected event [obs] `T:833`-`T:7097`

1. Get route (§4.2).
2. Router header of the new router, 1 then 5 dwords.
3. Capability chain walks (sub-ids 1, 3/4/5 headers).
4. DMA port probe: adapters 3 and 5, then outbound word of the DMA port.
5. Plug-events capability (13 dwords), EEPROM bit-bang of the DROM size, plug-events
   again, bit-bang of the full DROM.
6. Port dword 2 of every enabled adapter, then each adapter's header (8 dwords) and
   capability chain.
7. DMA port flash reads for NVM size and version.

The host router follows the same pattern after driver-ready, with the link-controller
UUID read inserted after the chain walk and the NVM DROM reads before the EEPROM UID
read [obs] `T:15`-`T:831`. No link, TMU, CL-state, path or hop-table access happens under
the firmware CM [obs]: no writes other than §5 and no reads of config space 0 (path) by
the client; path-space reads in the trace come only from the capture tool's debugfs
dumps.

## 6. Sequences, as observed

Times are trace seconds unless marked dmesg.

### 6.1 Bind (inferred order, consistent with the observed end state)

1. Read host capabilities: 12 rings, version 0, so no host reset.
2. Clear all ring interrupt enables. Allocate MSI-X (else MSI).
3. Read firmware status: ICM enable set, take the firmware CM.
4. Allocate and start TX/RX ring 0 (raw, 10 entries, 256-byte RX buffers), enable their
   interrupts.
5. Poll firmware status for NVM authentication done; read the operating mode (3).
6. Mailbox 0x23 allow all devices.
7. Driver ready (§4.1), then poll the host router header until answered.
8. Read the host router (§5.1, §5.2, §5.4) and register it.
9. Process queued events (§6.2).

### 6.2 Rebind with the dock attached and approved [obs]

| Time | Event | Ref |
|---|---|---|
| 123.278 | driver ready sent | `T:1` |
| 123.284 | driver-ready response (6 ms) | `T:2` |
| 123.284-123.852 | host header polls get no answer; the sequence counter cycles 0-3 | `T:3`-`T:8` |
| 123.861 | device connected, id 5, approved | `T:9` |
| 123.866 | the queued first poll is answered (dropped as stale); the next poll succeeds at 123.956 | `T:10`, `T:11` |
| 123.96-124.01 | host router enumeration | `T:15`-`T:831` |
| 124.013 | get route, answered in 2.6 ms | `T:833` |
| 124.02-124.42 | dock enumeration, 390 ms of it the DROM bit-bang | `T:835`-`T:7097` |
| 124.42-124.58 | boltd reads, writes, re-reads the boot ACL | `T:7099`-`T:7106` |

So the firmware answers driver-ready at once, holds config requests for about 580 ms
while it announces attached devices, then serves the queued request.

### 6.3 Unplug while active [obs]

dmesg 151.680 (trace about 151.76): tunnel port 04:01.0 link down, card not present
(`D:1603`). Trace 151.771: device disconnected for link 1 depth 1 (`T:21087`). The client
removes 0-1; no config traffic, no commands.

### 6.4 Plug and approve, security `user` [obs]

| Time | Event | Ref |
|---|---|---|
| 173.984 | device connected, id 6, not approved | `T:27886` |
| 173.984-173.993 | get route | `T:27887` |
| 173.99-174.49 | dock enumeration, same reads as §6.2 | `T:27889`-`T:34147` |
| 174.497 | approve sent by boltd (policy auto) | `T:34153` |
| ~174.56 (dmesg 174.475) | tunnel port link up, card present | `D:1689` |
| 174.855 | approve response, no error | `T:34154` |
| dmesg 174.60 onwards | PCI enumeration of the dock's switch 06:00.0 `8086:15d3` and endpoints | `D:1691` |

Before approval no PCIe link exists [obs] (no link-up between 173.98 and 174.47).

### 6.5 Runtime suspend and resume [obs]

The domain runtime-suspends when idle for some seconds (dmesg 193.164 and 233.217:
rings stopped, then mailbox 0x07, NHI in D3 [obs] `M:5-plugged` INMAIL `0x07`, lspci
"Status: D3"). Resume (dmesg 193.758, triggered by the capture tool reading sysfs):

| Time | Event | Ref |
|---|---|---|
| 193.845 | driver ready (no mailbox 0x23 on resume [inf]) | `T:34155` |
| 193.848 | response, same values | `T:34156` |
| 193.85-194.42 | host header polls unanswered | `T:34157`-`T:34162` |
| 194.425 | device connected, id 7, approved: tunnel kept through the suspend | `T:34163` |
| 194.52 | host header poll answered | |

The client recognises the UUID and only updates id and key; no get route, no config
reads [obs]. Then it schedules a check 500 ms later that removes routers not re-announced
[inf].

### 6.6 Unplug while runtime suspended [obs]

dmesg 250.781: tunnel port link down (`D:2031`). The PCIe hot-plug wakes the domain:
trace 250.898 driver ready, 250.901 response, 250.908 host header answered at once (no
device to announce). No device-disconnected event is sent. dmesg 251.323: the client's
500 ms check removes 0-1 ("device disconnected", `D:2066`).

### 6.7 Unbind [obs]

dmesg at the unbind: 0-1 removed by the client, ring 0 stopped and interrupts disabled
(`0x38200` back to 0), mailbox 0x07 [obs] `M:2-unbound`. Firmware status and the
outbound mailbox are unchanged, ring registers read 0.

## 7. Security level `user` behaviour

- Driver ready reports level 1 [obs]. The client sets the domain to `user` and offers
  `authorized` on each device [inf]; Linux's `deauthorization` attribute is 0 (no
  per-device de-authorisation on this generation) [obs]
  `S6:sys-bus-thunderbolt/domain0/deauthorization`.
- A newly plugged device is announced with approved = 0 and has no PCIe tunnel until an
  approve command; the tunnel comes up while the approve is processed [obs] §6.4.
- A device approved earlier keeps its tunnel across driver unbind, rebind and runtime
  suspend, and is re-announced with approved = 1 [obs] §6.2, §6.5.
- After an unplug and re-plug the device must be approved again [obs] §6.4.
- The boot ACL holds device UUIDs for pre-boot connection; with pre-boot support off it
  did not cause an automatic approval [obs] §6.4 (the dock is in the list, yet was
  announced unapproved). With pre-boot support on, the dock was tunnelled before the OS
  and reported with `boot` = 1 [obs] §12.1, and so was the ORICO, which was not in the
  ACL [obs] §13.2.

## 8. Emulator requirements (`tb3-alpine-ridge`)

Each is testable by qtest or by a guest trace compared with §6.

- **R1** PCI identity of the NHI: `8086:15bf`, revision 1, class `0x088000`, subsystem
  `17aa:22b0`, BAR0 256 KiB 32-bit, MSI capability with one vector and 64-bit address,
  INTx pin A (§1). MSI-X 16 vectors with the table in BAR1 is optional (R7).
- **R2** BAR0 reset state: capabilities `0x0000000c`, firmware status `0x800001a1`,
  outbound mailbox `0x800003f0`, DMA misc `0x01000012`, throttle entries `0x1f4`,
  everything else 0 [obs] §13.5 (W98 A1P1_OR, Linux mmio dumps of R1-R4). The outbound
  mailbox's low nibble becomes 5 (`0x800003f5`) once the NHI has entered D3 (PMCSR
  PowerState 3, writable on the TB3 profiles) and stays so until device reset [obs]
  R1-W:145.874. DMA misc bit 2 is the client's auto-clear enable (R7); `0x01000016` in
  §2.1 is the value after a client bound. These hold across guest driver unbind and are
  restored by device reset. (Before 2026-10-15 the model reset to the §2.1 values.)
- **R3** Mailbox: a write to 0x39904 with bit 31 set performs the command in bits 7:0
  and clears bit 31 before the next guest read can observe it set for longer than the
  command takes; bits 7:0 keep the code; bit 30 is set only for unsupported codes.
  Supported: 0x05, 0x06 (tear down all PCIe tunnels, closing the access gate
  synchronously as `ARCHITECTURE.md` §4.4 requires), 0x07 (forget the driver: stop
  sending events, keep tunnels and approvals), 0x23 (no effect beyond completing). 0x10
  and 0x11 complete without effect. Anything else sets bit 30.
- **R4** No host-reset handshake is required (version 0) and the firmware-start path of
  §2.7 is not implemented; the upstream-port vendor capability need not exist.
- **R5** Ring 0 in raw mode carries ICM frames with frame types 10, 11, 12; responses and
  events carry a 4-byte CRC-32C trailer; frames up to 248 bytes plus trailer.
- **R6** Interrupt status, single MSI or INTx: reading a status dword clears the bits
  read; delivery does not clear (`ARCHITECTURE.md` §4.1). Polling works without any
  interrupt.
- **R7** If MSI-X is offered: honour the vector allocation registers and the auto-clear
  bit (DMA misc bit 2): when set, sending a ring's MSI-X message clears that ring's
  status bit. The captured guest used MSI-X; offering only MSI is an accepted deviation
  that drives the read-to-clear path instead.
- **R8** Driver ready: answer within a few milliseconds with 2 words, flags `0xe2` with
  bit 6 cleared unless the RTD3 property is on (`0x22` under BIOS Assist [obs] §13.5,
  R4-T:86.764), ROM `0x60`, RAM `0x0b`, info security level (property, default 1), boot
  ACL supported with 16 entries (property may set 0 and clear bit 29). Then announce
  every attached device (R11) before or while answering config requests; config
  requests must never be dropped, only delayed. Hold (2026-10-15): when a device is to
  be announced, config requests are queued for `first-ready-hold-ms` after the first
  driver ready since power-on (`-1` auto: 2770 with `bios-assist=on` on Alpine Ridge
  [obs] §13.5 R4, else 0) or `ready-hold-ms` after later ones (default 0; 580 observed
  §6.2), then the devices are announced and the queued requests served in order. With
  nothing to announce there is no hold [obs] §6.6. The queue is bounded (16); when it is
  full the NHI leaves further ring 0 TX descriptors pending (not completed) until the
  hold drains, so no request is lost (model choice; the real queue depth is unknown).
- **R9** Get route: for link L, depth 1, return route string L if a device router is
  attached there, else the request words with flags bit 0. Echo word 1.
- **R10** Approve: look up the device by UUID, connection key and id; program the PCIe
  paths and enables in the fabric as a software CM would (`ARCHITECTURE.md` §4.2b),
  synchronously with respect to the response; respond with the 6 request words and flags
  0. Unknown UUID, stale id, or a fabric failure: flags bit 0. Approving an already
  approved device succeeds. Optional observed timing: `approve-link-ms` (tunnel up) and
  `approve-resp-ms` (response) after the request, default 0 (synchronous); the ORICO
  took 89 and 383 ms [obs] §13.3, the dock about 60 and 358 ms §4.3. A second approve
  while one is in progress fails. The approve is bound to the connection it named: an
  unplug, a replug or mailbox 0x06 in between invalidates it, so neither timer builds
  a tunnel for another connection and the response carries the error flag.
- **R11** Device connected, 61 words: flags `0xb1` (dual lane, 20 Gb/s, observed level
  and bit 0), UUID (bytes 8-15 all ones, bytes 0-7 equal the DROM UID), key `0x10`, a
  fresh connection id per announcement (ids increase, wrap within 8 bits, never repeat
  for a router still announced), link info with link = host lane adapter, depth 1,
  approved bit as the tunnel state, bit 11 set, and the endpoint name block with vendor
  name, model name and the Intel vendor-specific entry (RTD3 flag from a property). This
  is the Thunderbolt 3 device router form. A USB4 device router (`dialect=usb4`, e.g.
  `device-model=asm2464`) is announced as observed in §13.3 (implemented 2026-10-15):
  flags `0xa8` (`0x88` when pre-boot tunnelled it under BIOS Assist), UUID words 1-2 =
  ROUTER_CS_8, ROUTER_CS_7, vendor and model names and the Intel entry from its DROM
  (flags byte bit 1 set), no type `0x12` entry; the firmware sets its Notification
  Timeout to 254 ms and Configuration Valid. Its router operations (DROM Read, NVM
  Sector Size) are forwarded like any non-path write (R31).
- **R12** Announce on: hot-plug while a driver is ready; every driver ready, for every
  attached router, in adapter order. Never announce while the driver is unloaded (after
  0x07 until the next driver ready).
- **R13** Device disconnected, 2 words, link info with link and depth: on unplug while a
  driver is ready and only for an announced router. Unplug while unloaded sends nothing.
- **R14** Boot ACL: 16 slots initialised empty (or from a property); read returns them;
  write stores them and answers with flags `0x80` and zero entries. The ACL has no effect
  on approval.
- **R15** ICM command codes 0x01, 0x05, 0x06, 0x10, 0x11, 0x20 and unknown codes: respond with the
  request header (index 0, count 1) and flags bit 0 set.
- **R16** All responses and events: packet index 0, packet count 1.
- **R17** Host router config space per §5.1: header with device `0x15c0`, upstream
  adapter 3, highest adapter 5; the capability chain at the same dword offsets; plug-
  events capability with present = 1 and DROM offset 0x210; link-controller UUID at
  0x102. Replies carry adapter 3 in the adapter field. Unimplemented router dwords return
  error code 2.
- **R18** Host adapters 1-5 with the types of §5.1. Adapter 3 is the upstream adapter.
  Per `ARCHITECTURE.md` §4.2 adapter 3's type is not NHI unless the read-only DMA port
  (R20) is enabled.
- **R19** EEPROM bit-bang state machine of §5.4 on every tb3 router: SPI read command
  0x03 with a 16-bit address, MSB-first bits, data valid in bit 3 after the clock goes
  high. Host EEPROM holds CRC-8 plus UID at 0x210; device EEPROM holds the full DROM at
  0x210 with valid CRC-8 and CRC-32C.
- **R20** Optional read-only DMA port: NHI-typed adapter (host 3, device 5), mailbox of
  §5.2 with flash read only; other commands complete with status 2. Flash image provides
  the DROM length and copy at 0x210, the flash size byte at 0x45 and the version dword at
  0x08. Implemented for the dock under a software CM on a USB4 host (`usb4-win11tb3`,
  2026-10-16, in main as of QEMU `2a893ea`, `USB4-HOSTS.md` §8); still off on the `tb3-*` profiles.
- **R21** Device router: Intel TB3 router device ID (`0x15d3` as captured, or `0x15c0`),
  upstream adapter 1, depth 1, route = host lane adapter; lane, PCIe up, PCIe down and
  disabled adapters as needed; same capability layout; replies carry adapter 1. No
  Configuration Valid handshake.
- **R22** Tunnel lifecycle: the PCIe tunnel exists only after approve (or always, under
  `security=none`); it survives driver unload, rebind and resume; it goes down on unplug
  or mailbox 0x06, through the synchronous gate.

Added after the Windows 11, Windows 98 and Assist-on captures (§10-§12):

- **R23** The NHI class code `0x088000` is mandatory, not cosmetic: the Intel Windows
  INF matches `PCI\VEN_8086&DEV_15BF&CC_0880` (§10.1).
- **R24** MSI-X with 16 vectors in BAR1 (R7) must exist before the Windows smoke gate:
  Windows allocated all 16 messages on the real controller (§10.2). MSI and INTx stay
  for Linux fallback and legacy guests.
- **R25** Pre-boot property (`preboot=on`, default off, matching the BIOS option). At
  machine power-on (emulator cold reset, not guest driver reload) the ICM approves every
  attached device, in the boot ACL or not [obs] §13.2, and builds its PCIe tunnel
  before the guest firmware enumerates PCI, so the endpoint and the tunnel port's
  presence and link are visible to a driverless guest (§12.1). While pre-boot is on
  every announcement carries boot = 1 (link info bit 10), also for a device plugged
  later and not approved [obs] §13.2 (`0x0c110210`); sysfs `boot` reads 1. A device
  hot-plugged after power-on is not auto-approved. `preboot-acl-only=on` keeps the
  pre-2026-10-15 model (only boot-ACL devices are approved; no capture supports it).
- **R26** The boot ACL survives emulator reset when pre-boot is used: it is
  initialised from a property (list of UUIDs) and writes from the guest persist for the
  life of the QEMU process. With `preboot=off` the ACL has no effect (R14).
- **R27** Power model, tied to BIOS Assist: with Assist on and no device attached at
  power-on, nothing exists below the TB root port, whatever pre-boot is set to: the root
  port's link is down and its slot reports no presence [obs] Windows 98 `ON_ON_NO` and
  `ON_OFF_N` (§12.2). With Assist off the controller stays powered with nothing attached
  [obs] `OFF_OFF_N`, `OFF_ON_N`. Force power (R28) or a device makes the controller
  appear (root-port link up, presence, hot-plug event to the guest); when the last device
  leaves and force power is off it disappears again after a delay (observed about 35 s,
  §12.3). Implemented as `usb4-host` `bios-assist=on` with `power=auto` (default);
  `power=always` overrides.
- **R28** Optional ACPI force power for R27: a WMI-style method on the platform, modelled
  on the captured `TBFP` interface (§11.2), backed by a register the emulator watches.
  Not needed for Linux, which has no force-power support.
- **R29** Optional PCIe Device Serial Number capability on the NHI and switch functions
  (q35 only): Windows builds its device instance IDs from it (§10.1), so a stable value
  keeps Windows device identity, and the stored per-device approval, stable across boots.
- **R30** BIOS Assist (`bios-assist=on`): ACPI-owned hot-plug (q35 `PCI0._OSC` grants
  only LTR and DPC, §11.3), the integrated xHCI `8086:15c1` hidden (its downstream port
  stays), and power-down when empty (R27). With the host's `xhci=<id>` property the
  model hides the `usb4-tb3-xhci` itself (config space reads all-ones), or shows it
  without resources after a USB fallback (R33); the launchers always create it. How the
  firmware hides the xHCI is not modelled beyond that.
- **R31** Firmware ownership of tunnel state (emulator decision, 2026-10-14): under the
  firmware CM the guest's control packets may read any config space, but writes to path
  config space and to a PCIe adapter's protocol capability (Path Enable) are answered
  with a normal write response and ignored. Basis: the client never writes there [obs]
  §5 (only the EEPROM control dword and the DMA-port mailbox), and approval (R10) is the
  only way a tunnel comes up [obs] §6.4. How the real firmware treats such writes is not
  captured. Mailbox 0x06 (R3) tears down every PCIe tunnel regardless of how it came up.
- **R32** Silence before the power-off (BIOS Assist): with Assist on, from the moment the
  last device leaves (and force power is off) until the platform removes the controller,
  the firmware answers no ICM command. The device-disconnected event is still sent. [obs]
  Assist-on `trace-thunderbolt.txt`: disconnected event at 96.75 s (line 1), then the
  client's boot-ACL read sent four times at 110.55, 116.02, 121.14 and 126.26 s (lines
  2-5) with no response; at 131.80 s the ring registers read all-ones and the controller
  was removed (Assist-on `dmesg-live.txt`; `CAPTURE-VS-LINUX.md` AR-28, AR-48, C2). The
  exact start of the window is not captured: no command was sent between 96.75 and
  110.55 s, so "from the departure" is the model's choice [inf]. Whether NHI mailbox
  commands and control packets are answered in the window is not captured; the model
  answers them. A device plugged before the power-off ends the silence [inf]. Implemented
  as `usb4-host` `assist-icm-silence` (default on; applies only with `bios-assist=on`
  and `power=auto`); off keeps the ICM answering until the power-off. Timing from the
  2026-10-15 ORICO run [obs] §13.4: the controller's registers read all-ones 10.4-11.4 s
  after the departure (OS-visible removal at 15.4 s), and the replug did not bring it
  back; no command was sent in those 11 s, so the start of the silence is still not
  captured. In the dock run the controller was still present at +15.9 s (the platform
  removed only the dock's devices then) and silent from +13.8 s, so there the silence
  preceded the power-off [inf]. `power-off-delay-ms=35000` fits the dock; the ORICO
  needs about 11000: `power-off-delay-usb4-ms` (default 0 = `power-off-delay-ms`)
  applies when the last device to leave was a USB4 device router.
  The platform's removal after the power-off (OS-visible at 15.4 s in R4 [obs], through
  the `WHL_Tbt` bus check to the root port, §11.1 [inf for the mechanism]) is modelled
  in main as of QEMU `25fd4eb` by the i440FX root bridge: `root-hotplug=acpi` sends a
  Bus Check `removal-notify-ms` (default 4400) after the power-off, and
  `root-hotplug=restore` instead restores the tree's configuration on power-on for
  guests without ACPI ([ARCHITECTURE.md](ARCHITECTURE.md) §4.4a).

Added after the P14s ORICO session (§13, 2026-10-15):

- **R33** USB fallback of a USB4 device router §13.1. A USB4 (not TB3) device router
  that the firmware announced and nobody approved leaves the Thunderbolt link
  `usb-fallback-ms` after the announcement (default 9385 [obs] R1-T:151.727 to 161.112,
  a run-time replug; 0 = never): the ICM sends device disconnected without an unplug
  and the device runs as a USB 3 device [obs]. A TB3 router waits indefinitely (§6.4).
  At machine power-on a USB4 router the firmware does not approve itself (pre-boot off,
  or not in the ACL with `preboot-acl-only`) is already in USB mode when the guest
  starts: that the ORICO is a USB disk at boot with pre-boot off is [obs] (R1-D:1.51,
  W98 A0P0_OR); that it got there by the same fallback during POST, and how long that
  took, is [inf] (the boot trace is empty, P0, P2.2), so the model's immediate switch
  at power-on is a modelling choice. With the host's `xhci=<id>` (the
  `usb4-tb3-xhci`) the device appears there as a SuperSpeed USB disk backed by its
  NVMe drive, created and removed from a bottom half. `usb-fallback=uas` (in main as of QEMU
  `36f6254`) makes it a `usb-uas` with one `scsi-hd` that carries the captured
  identity: USB `174c:2463`, bcdDevice 1.00, "ASMedia" / "ASM246X series" at string
  indexes 2 and 3 [obs] R1-D:1.524; SCSI "ASMT" "ASM246X" revision "0", write cache
  off, 512-byte minimum and 2 MiB optimal transfer [obs] R1-D:1.633-1.663; Linux binds
  `uas` as on the P14s [obs] R1-D:1.631. The serial is the NVMe serial (the
  capture's is redacted) and its string index 1 is [inf]. UAS is the default on every
  machine type, i440FX included: xhci98 provides a UAS driver for Windows 98 to 7
  (`xhciuas.sys`, bound by interface class 08/06/62, which QEMU's `usb-uas` presents).
  `usb-fallback=bot` is an opt-in for guests without a UAS driver: QEMU's Bulk-Only
  `usb-storage` with QEMU's identity. QEMU's `usb-uas` has no Bulk-Only alternate
  setting, and whether the ASM246X offers one is not captured (no `lsusb -v`) [inf: UAS
  devices usually do]. `usb-fallback` is refused on profiles without the fallback. At
  SuperSpeed UAS uses bulk streams, which QEMU's xHCI supports; the TB xHCI works with
  INTx and 32-bit addresses (its MSI and MSI-X stay off unless the guest enables them;
  AC64 only means 64-bit capable). Not modelled: SuperSpeed Plus Gen 2x1 [obs] R1-D:1.510; QEMU's xHCI
  runs the device at 5 Gb/s. The disk goes with an unplug, and a power-on starts the
  device on USB4 again.
  If the drive is still held by the NVMe endpoint of a tunnel that just went down (a
  reset after an approval), creation waits and retries every 100 ms for up to 10 s,
  re-checking the port's device and mode each time. `xhci=` must name an xHCI with a
  USB bus, else the host reports a configuration error.
  Under BIOS Assist, when a device is in USB mode at power-on, the NHI is hidden for the
  session (config space all-ones) and the xHCI is present without resources (BARs read
  unimplemented, decode and bus master cannot be enabled; stand-in for the BIOS leaving
  it unassigned) [obs] §13.1 R3, W98 A1P0_OR; otherwise the xHCI is hidden and the NHI
  shown (R30). A fallback at run time under Assist keeps the NHI and the hidden xHCI
  [inf, not captured].

## 9. Open questions: status after the Windows 11, Windows 98 and Assist-on captures

1. Which ICM commands the Intel Windows driver sends, in what order: **still open**. The
   ETW trace has the driver's events but only as WPP records without format data, so
   their payload is unreadable (§10.4). The Windows event log shows the driver reports
   the host NVM version 23.0 and the dock's 44.0 and the dock's names [obs] §10.3; the
   names are equal in the DROM and the endpoint name block, so their source is not
   determinable.
2. MSI-X: **answered**, Windows uses MSI-X with 16 messages [obs] §10.2. Auto-clear and
   status-clear use are not visible.
3. DMA port: **partly answered**. The driver logs NVM versions that this generation only
   exposes through the DMA port (driver ready carries no NVM version) [obs] §10.3, so it
   very probably reads the DMA port [inf]; whether it fails without one is open (smoke
   gate). Topology: Windows binds only the inbox `pci.inf` to the switch ports [obs]
   §10.1; whether the Intel driver walks them is not visible. The platform ACPI, not the
   driver, uses the upstream port's vendor capability (§11.1).
4. ACPI: **answered** for the tables (§11); which methods Windows calls at run time is
   not in the capture.
5. Mailbox commands under Windows and the unexplained register bits: **still open**
   (no Windows MMIO dump; the Windows capture tool did not read BAR0).
6. Pre-boot: **answered** (§12.1). With pre-boot support on, the firmware tunnels the
   boot-ACL dock before the OS, a driverless Windows 98 sees the dock's PCIe tree, and
   Linux reports the device with `boot` = 1. Without it, the dock's PCIe devices are not
   visible to a driverless OS. Firmware status and mode under DOS: **answered** for
   Assist on + pre-boot on (2026-10-15, §13.5): firmware status `0x800001a1`, outbound
   `0x800003f0` (CM mode 3), DMA misc `0x01000012`, inbound command 0.
7. Unknown or malformed ICM commands: **still open**.
8. Security level 2 in device-connected flags: **open**; Windows stores the dock with
   "approved security level" 2 [obs] §10.3, which may be the same value.

## 10. Windows 11 with the Intel driver (capture `win11-assistOFF_prebootOFF`)

Windows 11 Pro 26200, BIOS N2XET46W 1.36, Assist off, pre-boot off, dock attached, plug
sequence during an ETW session. Prefix `W:` = path inside
`p14s-win11-20261014-135249-assistOff_prebootOff/`.

### 10.1 Driver binding [obs]

| Function | Driver | Evidence |
|---|---|---|
| NHI `8086:15bf` (bus 5) | Intel `tbthostcontroller.inf` (published `oem76.inf`) 1.41.1353.0, 12/12/2022, service `nhi` = `TbtBusDrv.sys`, KMDF; extension INF `tbthostcontrollerextension.inf`; UMDF upper filter `TbtFilterDrv` via `WUDFRd` (it failed to load once: event "driver \Driver\WUDFRd failed to load", status 0xC0000365). Matched by `PCI\VEN_8086&DEV_15BF&CC_0880`. Children: two software components (HSA, toast). | `W:pnp/pnputil/016-*`, `W:registry/enum/035.txt`, `W:logs/events-System.txt` |
| Switch `8086:15c0` upstream port and its three downstream ports | inbox `pci.inf` ("PCI Express Upstream/Downstream Switch Port") | `W:pnp/pnputil/021-024*` |
| Integrated xHCI `8086:15c1` (bus 2b) | inbox `usbxhci.inf` | `W:pnp/pnputil-enum-pci.txt` |
| Dock router's PCIe switch `8086:15d3` (subsystem `1ab6:0011`) | inbox `pci.inf` | `W:pnp/pnputil/025-036*` |
| Services | `TbtHostControllerService` (ThunderboltService.exe, "Application Launcher"), `TbtP2pShortcutService`; UWP app "Thunderbolt Control Center" 1.0.37.0; `tbtp2pndisdrv.inf` (host-to-host networking) | `W:drivers/*` |

Instance IDs of the controller's functions are built from the PCIe Device Serial Number
(e.g. `...\A615985088C9A00000`), which Windows reads from the DSN extended capability;
the same 64-bit value is reported as the NHI's and its parent's serial number [obs]
`W:pnp/props/016-*`. Stale instances from other boots appear with `Unknown` status
[obs] `W:pnp/tb-devices-summary.txt`.

### 10.2 Resources [obs] `W:pnp/pnputil/016-*`, `W:registry/enum/035.txt`

- NHI memory: `E0100000-E013FFFF` (BAR0, 256 KiB) and `E0140000-E0140FFF` (BAR1, 4 KiB).
- Interrupts: 16 message-signalled vectors; `MSISupported` = 1, `MessageNumberLimit` =
  16; PnP reports interrupt support 7 (line, MSI, MSI-X) and a 16-message maximum.
- Windows marks the NHI "S0 wakeup supported" and enables WDF idle in the working state
  (`IdleInWorkingState` = 1), so the driver runtime-idles the NHI as Linux does.
- Driver parameters: `DmaRemappingCompatible` = 1, `PowerPolicyIdleTimeoutType` = 2,
  host-to-host shortcut off.
- Bridge windows: upstream port `D4000000-E01FFFFF` plus prefetchable
  `A0000000-BBFFFFFF`; NHI port `E0100000-E01FFFFF`; tunnel port `D4100000-E00FFFFF` plus
  the prefetchable window; xHCI port `D4000000-D40FFFFF`.

### 10.3 Driver state and logs [obs]

- System log, provider `nhi`: event 9001 "driver is loaded and initialized connection to
  HW", driver 1.41.1353.0, NVM version 23:0; event 9002 "Thunderbolt device is
  connected", TS3 Plus, CalDigit, Inc., NVM version 44:0; event 9003 on disconnect
  `W:logs/events-System.txt`.
- Approved devices are kept under the `nhi` service key, one subkey per device named by
  the four UUID words (`A0211100:003D0EFC:FFFFFFFF:FFFFFFFF`), with
  `ApprovedSecurityLevel` = 2 and the vendor and model names
  `W:registry/services/nhi.reg.txt`. The Windows service approves a stored device on
  plug without user interaction [inf]. There is no Intel key under `HKLM\SOFTWARE`.

### 10.4 ETW [obs]

Five providers were enabled (`W:etw/providers-used.txt`); 40,039 events in 91 s. Apart
from Kernel-PnP, every record is a WPP message with "No Format Information found"
(13 message GUIDs, e.g. `c358eb56-...`), i.e. driver trace messages whose layout is in
the driver's private symbols. No ICM payload can be recovered from it.

## 11. Platform ACPI (DSDT and the `WHL_Tbt` SSDT)

Decoded with a local AML-to-text tool from the tables in `W:acpi/reg-*` (identical to
the Linux capture's `firmware/acpi/`). Names below are the platform's ACPI object names,
which are facts about this machine's firmware. The TB root port is `\_SB.PCI0.RP05`
(00:1c.4).

### 11.1 Root port RP05 (in SSDT `WHL_Tbt`) [obs]

- `_DSD` with two property sets: "HotPlugSupportInD3" = 1, and "ExternalFacingPort" = 1
  with "UID" = 0. `_S0W` = 4 (D3cold wake capable).
- `_PR0` and `_PR3` both return power resource `PXP`, so Windows can put the whole TB
  controller into D3cold by turning `PXP` off (runtime D3, "RTD3").
- `PXP._ON` (method `PON`): if the platform's RTD3 setting allows, raises the power GPIO
  `PWRG` (pad 0x4060004), releases the reset GPIO `RSTG` (pad 0x4060006), drives the
  root port out of L2/L3 and waits for its link, then waits up to 200 ms until the
  controller's upstream port answers config reads at offset 0x548 with something other
  than all-ones. If a handshake is enabled it writes `0x209` to the upstream port's
  config dword 0x54C and polls dword 0x548 bit 0 (up to 200 x 5 ms), then writes 0.
- `PXP._OFF` (method `POFF`): reads presence on the controller's downstream ports (their
  config space at fixed bus/device offsets below the upstream port); if a device is
  present it aborts and sends a bus-check notification instead of powering off.
  Otherwise it moves the root port to L2/L3, asserts reset, drops the power GPIO (unless
  wake is armed) and waits a platform delay.
- Upstream-port mailbox used by ACPI: dwords 0x540 (firmware to PCIe, "ICM" channel),
  0x544 (PCIe to firmware, "ICM" channel; bit 0 also used as a hot-plug flag), 0x548
  (firmware to PCIe, driver channel) and 0x54C (PCIe to firmware, driver channel), all
  inside the vendor-specific extended capability at 0x500 (ID 0x1234) seen in lspci
  [obs] §1. Commands are written with bit 0 set; completion is bit 0 of the reverse
  register. Values seen: `0x0d` ("OS up", sent by method `OSUP` on the driver or ICM
  channel at init and from the hot-plug handler when the controller has vanished) and
  `0x209` (sent by `PON`).
- `_GPE.XTBT` is the TB hot-plug event handler: if the controller is absent (upstream
  port reads all-ones) it sends "OS up" through the mailbox, then notifies RP05 with a
  bus check. Wake GPIO `WAKG` is pad 0x4060007.

### 11.2 Force power [obs]

`\_SB.TBFP(on, port)` drives the force-power GPIO `FPG0` to its active level `FP0L`
(both from platform NVS) when `on` is 1 and to the inactive level when 0. It is reached
from two places: the Lenovo WMI/EC dispatcher (codes 0x301 = on, 0x302 = off) and the
WMI device `\_SB.WTBT` (`_HID` PNP0C14, `_UID` "TBFP") whose `_WDG` exports method id
"TF", instance 1, GUID `86CCFD48-205E-4A77-9C48-2021CBEDE341`; its method `WMTF` takes a
one-byte buffer (1 = force power on, 0 = off). This is the interface an OS driver uses
to power a controller with nothing attached [inf]; Linux has no user of it.

### 11.3 `_OSC` and settings [obs]

- When the platform's TB support flag `TBTS` is set, `PCI0._OSC` withholds AER control
  from the OS. The Linux Assist-on dmesg shows the platform granting only LTR and DPC
  and retaining PCIe hot-plug, PME and AER ("platform retains control of PCIe
  features"); the Assist-off dmesg shows the OS getting native PCIe hot-plug, SHPC, PME,
  PCIe capability, LTR and DPC [obs] Assist-on `dmesg-live.txt` lines 358-363,
  Assist-off `dmesg-live.txt` line 361. So BIOS Assist means ACPI/SMM-owned hot-plug.
- RP05 `_PRW` uses the TB wake GPIO when TB is enabled on that port.
- Settings that steer all of this (`TBTS`, `RTBT`, `RTBC`, `TBOD`, `TBCD`, `TWIN`, the
  GPIO numbers) live in platform NVS whose contents are not in the capture.

## 12. BIOS options: pre-boot support and BIOS Assist

### 12.1 Pre-boot support (Windows 98 matrix, Linux Assist-on run) [obs]

Windows 98 SE in MS-DOS mode, dock plugged at power-on; config space only (256 bytes per
function, so no extended capabilities). `P98:` = `tests/captures/p14s-gen1/win98/`.

| Item | Pre-boot off (`OFF_OFF`, `ON_OFF`) | Pre-boot on (`OFF_ON`, `ON_ON`) |
|---|---|---|
| Root port 00:1c.4 | link up, presence, buses 03-2b, memory `D4000000-E01FFFFF`, prefetchable `A0000000-BBFFFFFF`; I/O window only with pre-boot on (`0x4000-0x4fff`) | same |
| Switch 03:00.0, DSPs 04:00/01/02 | present, command 0x0007, D0, MSI off | same |
| Tunnel DSP 04:01.0 | no presence, link down, slot status 0 | presence, link up, slot status `0x0148` (presence, presence changed, link changed) |
| NHI 05:00.0 | command 0x0002 (memory only, no bus master), BARs assigned, INTx line 11, D0, MSI and MSI-X disabled | same |
| Dock tree (06:00.0 `15d3` upstream, 07:00-04 DSPs, 2x FL1100, ASM1142, I210) | absent | present, enumerated and configured by the BIOS (BARs assigned, command registers set) |

So with pre-boot support on, the firmware CM approves the boot-ACL dock and builds its
PCIe tunnel before any OS driver runs, and the BIOS enumerates the devices behind it.
The dock is in the boot ACL (§4.6). The ACL is **not** the criterion: on 2026-10-15
the ORICO was tunnelled before the OS while it was not in the ACL [obs] §13.2.

Linux under Assist on and pre-boot on: the dock was authorised at boot without any
approve command and sysfs reported `boot` = 1 [obs] Assist-on
`snap-1-initial/sys-bus-thunderbolt/0-1/boot`; the client takes that attribute from link
info bit 10 of the device-connected event [inf]. The tracepoints started after boot, so
the event and the driver-ready values of this run are not captured. Boot ACL contents
are the same two entries as in the Assist-off run [obs] `.../domain0/boot_acl`.

### 12.2 Nothing attached at power-on (`ON_ON_NO`) [obs]

With Assist on, pre-boot on and nothing plugged, no device exists on buses 03-2b. The
root port 00:1c.4 keeps its bus range and windows but reports link down and slot status
`0x0108` (no presence; presence and link changed). The controller is powered down. To
bring it up an OS must assert force power (§11.2) or power the root port's `PXP`
resource (§11.1), wait for the link, then rescan the root port's secondary bus [inf].
The capture has no Assist-off variant without a device, so whether Assist off also
powers the controller down at boot is open.

### 12.3 BIOS Assist [obs]

- The integrated xHCI `8086:15c1` is absent with Assist on (Windows 98 `ON_*`, Linux
  Assist-on lspci), and its DSP 04:02.0 has no presence and a closed memory window
  (`fff00000-000fffff`). The NHI moves to `E0000000` because of that. Why the firmware
  hides it is not visible in the captures; the most likely reason is that Assist mode
  targets OSes without the Intel driver and exposes the USB controller only on demand
  [inf].
- Linux in Assist mode gets no native PCIe hot-plug (§11.3): after the dock was
  unplugged the device-disconnected event arrived (Assist-on `trace-thunderbolt.txt`
  line 1, 96.75 s) but no PCIe hot-unplug; the dock's PCIe drivers timed out, and about
  35 s later the whole controller below the root port was removed (dmesg 131.80, ring
  registers already reading all-ones) and never returned on re-plug within the run.
  Boot-ACL reads sent in between timed out (lines 2-5): the firmware no longer answered
  (R32). The NHI runtime status stayed `active`, so the RTD3 flag was probably clear in
  this mode [inf]; confirmed 2026-10-15: under Assist on the driver-ready flags are
  `0x22` (bits 7 and 6 clear) [obs] §13.5.
- The model does not implement Assist mode (R30); legacy guests that need the dock
  without a driver use pre-boot (R25) instead.

## 13. USB4 device on the Alpine Ridge firmware CM (2026-10-15)

ORICO AAGM2-U4 (ASMedia ASM2464PD USB4 device router), BIOS N2XET46W 1.36, security
`user`, CSM. Runs `R1` (Assist off, pre-boot off), `R2` (off, on), `R3` (on, off), `R4`
(on, on) under Linux, and `win98-orico/` under DOS. Full analysis, citations and the
`$PIR` decode: [captures/P14S-ORICO-2026-10-15.md](captures/P14S-ORICO-2026-10-15.md)
(section numbers below as `Pn`).

### 13.1 Power-on behaviour per BIOS setting [obs] P2.1

| | Pre-boot off | Pre-boot on |
|---|---|---|
| Assist off | NHI and TB xHCI present, no tunnel; the ORICO is a USB 3.2 UAS disk on the TB xHCI before the OS; the first driver-ready announces nothing | tunnel before the OS, announced with approved = 1, `boot` = 1, 2 lanes |
| Assist on | **NHI hidden**; TB xHCI present but left without resources by the BIOS; the device is unusable to the OS | NHI present, TB xHCI hidden, tunnel before the OS, `boot` = 1, **1 lane** |

Mechanism [obs] R1, P2.2: a USB4 device announced but not approved leaves the
Thunderbolt link 9.4 s later (device-disconnected event without an unplug) and comes
back in USB mode on the controller's xHCI. With pre-boot off the device is already a
USB disk when the OS starts [obs]; that this is the same fallback, run during POST, is
[inf] (the boot trace is empty). With Assist on the firmware then exposes the xHCI and
hides the NHI
[inf: it exposes whatever function matches the attached link, cf. the dock, §12.3].

### 13.2 Pre-boot and the boot ACL [obs] P2.3, P2.4

The ORICO was tunnelled at power-on in R2 although the last boot-ACL read of the boot
before (R1) did not list it; only an OS client writes the ACL. A device plugged later
with pre-boot on was announced with approved = 0 and `boot` = 1 (`0x0c110210`).

### 13.3 Event content and client traffic for a USB4 device router [obs] P4

- Header flags `0xa8` (dual lane, 20 Gb/s, level field 1, bit 0 clear); `0x88` (single
  lane) under Assist on + pre-boot. The dock: `0xb1`.
- UUID words 1-2 = router UID bits 63:32 then 31:0 (ROUTER_CS_8, ROUTER_CS_7): event
  `0x70912700 0x174c608e`, sysfs `00279170-8e60-4c17-ffff-ffffffffffff`, while the
  Framework's software CM shows `8e604c17-0027-9170-...`. The dock's words are its DROM
  UID low then high.
- Name block: "ASMedia", "246x", Intel vendor entry `b8 00 63 24 11 02` (DROM vendor
  `0x00b8`, device `0x2463`, `0x11`, flags `0x02`: RTD3 clear), no type `0x12` entry.
- Key `0x10`, link 1, depth 1, bit 27 set, as for the dock. Get route answers route 1.
- Approve: same request layout; tunnel link up 89 ms after the request, response after
  383 ms, flags 0.
- Client traffic on route 1: 85 requests in 13 ms; DROM by the DROM Read router
  operation (ROUTER_CS_25/26, opcode `0x24`) and NVM Sector Size (`0x25`, status 2),
  three each per enumeration. Router header `0x2463174c 0x001101c0 0x00000001
  0x80000000 0x200000fe` (Notification Timeout 254 ms). Linux: "USB4 Switch: 174c:2463",
  generation 4.

### 13.4 Assist on: departure to power-off [obs] P3

R4: device disconnected at 110.876 s; NHI registers normal at 121.27 s and all-ones at
122.27 s; platform removal of buses 04-2b at 126.2 s; no return on replug. See R32.

### 13.5 Register values [obs] P6, P7

- Under DOS (W98 A1P1_OR, Assist on + pre-boot on): caps `0x0000000c`, DMA misc
  `0x01000012`, inbound command 0, outbound `0x800003f0`, firmware status `0x800001a1`.
- Linux: outbound `0x800003f0` through every bind, unbind and rebind until the NHI first
  entered D3 by runtime suspend, `0x800003f5` after that; once `0x800013f5` for under a
  second.
- Driver-ready response: `0x0100e203 0x28010b60` with Assist off, **`0x01002203
  0x28010b60`** with Assist on.
- First driver-ready after power-on to the host router answering: 0.13 s with nothing
  to announce, 0.80 s with the pre-boot ORICO (Assist off), **2.77 s** with Assist on +
  pre-boot; about 0.6 s after a rebind (dmesg timing, the boot trace was empty).

### 13.6 Endpoint reset (MD-2) [obs] P5

After unplug and replug the ASM2464 switch and the NVMe re-enumerate from reset (bus
numbers 0, Command 0). A pre-boot tunnel reaches the OS without a reset, and a driver
rebind does not touch the tunnel or the endpoint.

### 13.7 Model status and Linux comparison (2026-10-15)

Implemented on QEMU branch `usb4-p14s`, in main as of `b5936c4`: R2, R8 (flags and hold), R10
(timing), R11 (USB4 form), R25, R30, R32 (`power-off-delay-usb4-ms`) and R33 above, for
`device-model=asm2464` (or any `dialect=usb4` router) behind `tb3-alpine-ridge`.
Unmodified Kubuntu 26.04.1 (kernel 7.0.0-30) with `scripts/run-linux.sh BIOS=<cell>
DEVICE_MODEL=asm2464` (observed approve timing and 11 s power-off on), compared with
`tests/captures/p14s-gen1/linux-orico-*`:

| Cell | Emulator | Capture |
|---|---|---|
| Assist off, pre-boot off | USB disk on the TB xHCI before the NHI driver (the model switches at power-on; the real POST timing is not captured) (SuperSpeed, `usb 2-1`, `sda`); first driver ready announces nothing; replug: `0-1` registered, "device disconnected" 9.35 s later, then the USB disk | same; 9.36 s (R1-D:151.668 to 161.026) |
| Assist off, pre-boot on | `0-1` `boot` 1, authorized, `00279170-8e60-4c17-...`, ASMedia 246x, 2 lanes, generation 4, "USB4 Switch: 174c:2463 (Revision: 0, TB Version: 32)", NVMe at boot without "enabling device"; boltd stores it and adds it to the ACL; replug: id 2, approved 0, boot 1, boltd approves with `... 0x00000210`, endpoint re-enumerates from reset | same (R2) |
| Assist on, pre-boot off | NHI absent, no Thunderbolt bus, `xhci_hcd 0000:05:00.0: init 0000:05:00.0 fail, -16` | same message for 2b:00.0 (R3-D:1.148); the capture also logs "can't assign; no space" for the BAR, the model's stand-in has no BAR |
| Assist on, pre-boot on | NHI present, xHCI hidden, `boot` 1, 1 lane; "starting RX ring 0" to "security level set to user" 2.80 s; after the unplug the controller is powered off 11.0 s later | same; 2.77 s; 10.4-11.4 s (R4) |

Not modelled: the ACPI-driven removal of the bridges after the power-off (R4-D:126.2).

Added on QEMU branch `usb4-orico2` (2026-10-15, in main as of `36f6254`), verified by qtests
only: the USB side is UAS with the captured identity (R33, `usb-fallback`), and the
ASM2464's PCIe link registers are the captured ones [obs] R2 and R4 lspci of 06:00.0,
07:00.0, 08:00.0, same on the Framework except the endpoint width: upstream port Link
Capabilities `0x01436811` (Port 1, 2.5 GT/s x1, ASPM L1), Link Status 2.5 GT/s x1,
Link Capabilities 2 `0x018f1e1e` (2.5-16 GT/s, retimer presence detect), Target Link
Speed 16 GT/s; downstream port `0x007b6844` (16 GT/s x4, DL Active and bandwidth
notification reporting), Link Status 8 GT/s x2 with DL Active; the NVMe below it
`0x00476843` (8 GT/s x4), Link Status 8 GT/s x2 (x4 on the Framework). Link Control
stays the guest's, so ASPM is advertised and stays off. The host side of the tunnel
(the Alpine Ridge downstream port 04:01.0, captured at 2.5 GT/s x4) is unchanged. The
switch exists only on q35; the i440FX tunnel bridge has no ASM2464 ports.
