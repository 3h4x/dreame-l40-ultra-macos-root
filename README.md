# Rooting a Dreame L40 Ultra from macOS

Scripts and notes for rooting a **Dreame L40 Ultra** (`dreame.vacuum.r2492`) with [dustbuilder](https://builder.dontvacuum.me)'s
FEL image and installing [Valetudo](https://valetudo.cloud), driven entirely from an **Apple Silicon Mac**, with no Linux
box, no LiveSuit and no Google `fastboot`.

It follows the official guide, [valetudo.cloud → Dreame → fastboot method](https://valetudo.cloud/pages/installation/dreame/),
step for step. Only the host tools are replaced, because the standard ones do not work on macOS. It worked on one
robot, on 2026-09-26, with Valetudo 2026.08.0. The whole story, mistakes included, is in [JOURNEY.md](JOURNEY.md).

> **Read this first.** Rooting can brick your robot and voids the warranty. This is not an official tool of Valetudo,
> dustbuilder or Dreame. Read the official guide and understand every step before you run anything. Every command
> that writes to the robot is marked below, and the scripts refuse to write without an explicit mode.
> Runtime messages of the scripts are in Polish (the author's language); the usage headers are in English.

## Why not just follow the guide on a Mac

| The guide uses | Problem on macOS | Here |
|---|---|---|
| LiveSuit / `sunxi-fel` on Linux | LiveSuit does not exist for macOS | `sunxi-fel` built from source (pinned to Debian's version) |
| Google `fastboot` | The dustbuilder payload's gadget is `bDeviceClass 0xff`. macOS leaves it unconfigured, so `fastboot devices` shows nothing. Forcing it makes small commands work, but big transfers stall | [`tools/fbtool.c`](tools/fbtool.c), a small libusb fastboot client. It sends **the same command stream as Google fastboot** (checked byte for byte by [`tests/test-vs-fastboot.sh`](tests/test-vs-fastboot.sh)) |
| `fastboot flash` splitting big images | | [`tools/fbsparse.cpp`](tools/fbsparse.cpp): the same libsparse calls fastboot makes, built from Debian's source |

## What you need

- A **Dreame L40 Ultra**. Check the serial under the dustbin: it must start with `R2492`. Do not trust the box. The
  L40 Ultra **AE** and **L40s** are different robots and are not supported. Never fake a serial on dustbuilder.
- The **Dreame breakout PCB** ([Valetudo Dreame adapter](https://github.com/Hypfer/valetudo-dreameadapter); sold
  pre-made too) and a micro-USB cable to the Mac.
- **Strongly recommended:** a **3.3 V USB-UART adapter** (FT232RL with the jumper on 3.3 V, or CP2102) and 3
  male-female dupont wires. Over USB, a failed write only returns a bare `FAIL`. The real reason is printed only on the
  UART, and on this robot it was an eMMC write timeout (see [Troubleshooting](#the-emmc-write-timeout)). Wiring:
  [docs/breakout-pcb.md](docs/breakout-pcb.md).
- Apple Silicon Mac with the Xcode command line tools, [Homebrew](https://brew.sh) (`brew install libusb dtc`),
  python3.
- An **RSA** SSH key (`~/.ssh/id_rsa.pub`) for dustbuilder.
- Keep the robot **off the Dreame app and cloud** until it is rooted. The FEL entry lives in the SoC's boot ROM and
  cannot be broken by a bad flash, but a vendor OTA could change things.

The scripts keep their data in `$DATA` (default `~/dreame-l40`) and your dustbuilder job in `$JOB` (default
`$DATA/job`). Nothing personal ever goes into this repo.

## Entering FEL

Robot off. Pry off the front cover, then put the breakout PCB in the debug header with its top towards the lidar. Plug USB into the
Mac. **Hold the PCB's boot-select button, hold power for 5 s, release power, keep boot-select 3 s more.** The
lights pulse. The scripts wait up to 5 minutes for FEL, so start them first.

Turning it off again: hold power 15 s.

## Steps

**0. Toolchain** (no robot): `./scripts/setup-mac.sh`. This builds `sunxi-fel`, `fbtool`, `fbsparse` and `simg2img` into
`build/`, and fetches dustbuilder's stage1 FEL package into `$DATA`. Every third-party input is pinned by commit or
sha256.

Before any session: quit Chrome and anything else that uses USB, and set *System Settings → Privacy & Security →
Allow accessories to connect* to **Automatically when unlocked**. A prompt mid-session costs you the time window.

**1. Samples for dustbuilder** (robot, read-only): `./scripts/samples.sh`, then enter FEL. It reads `getvar config`
and the three ~400 MB samples into `$DATA`. You have about 160 s from the button press, so re-run it if it times out
(it resumes). On the r2492 page of dustbuilder, upload `config.txt` + `dreame_samples.zip` with your serial and
`id_rsa.pub`. Tick *FEL image*. *Patch DNS* and *preinstall tools* are what was used here.

**Keep the samples.** They are an encrypted copy of the first ~1.2 GB of the eMMC: bootloaders, both firmware slots,
env and your calibration (`private`, `misc`). [`tools/dustdecrypt.py`](tools/dustdecrypt.py) decrypts them. That is
your disaster-recovery backup, so copy it off the Mac.

**2. The job:** dustbuilder deletes it after a few days, so download it right away. Put
`dreame.vacuum.r2492_*_fel_ng.zip`, `md5.txt` and `_buildflags.sh` in `$JOB`.

**3. Prepare** (no robot): `./scripts/flash.sh prepare`. It checks the zip against `md5.txt`, `check.txt` against
`_buildflags.sh`, unpacks, and splits the rootfs into ≤ 32 MiB sparse pieces. Each piece is verified with libsparse
and with an independent parser, and the result is written to a sha256 manifest.

**4. Probe the DRAM set** (robot, no writes, no payload): `./scripts/flash.sh probe`. It runs dustbuilder's
`fsbl_ddr4.bin` and reads back from SRAM which DRAM parameters it used. On this robot it came back
`verdict=default` (DDR4, 792 MHz, 512 MB) — the job zip's own `fsbl.bin` defaults to DDR3, so it must **not** be
used. Run everything below with **`FSBL=ddr4`** (see [Troubleshooting](#the-fsbl-defaults-to-the-wrong-dram-set) for why).

**5. Rehearse** (robot, no writes): `FSBL=ddr4 ./scripts/flash.sh rehearse`. This loads the job's payload and checks
`getvar config` against the job, the getvars and `max-download-size`. It then downloads a rootfs piece and `boot.img`
to RAM only, and reads the whole eMMC window back to compare it with the images.

**6. Flash** (robot, **WRITES**). Attach the UART and start `./scripts/uart.sh` in another terminal first.

```
FSBL=ddr4 ./scripts/flash.sh flash
```

This runs `oem dust <check>`, `oem prep`, then flashes `toc1`, `boot1`, `rootfs1`, `boot2`, `rootfs2`. It stops at the first
non-`OKAY`, never reboots on its own, and reads the flash back at the end.

Expect the eMMC to time out after **~80–100 MB of writes** in a session (see
[Troubleshooting](#the-emmc-write-timeout)). If that happens: power off (15 s), re-enter FEL, and finish the
partition with `FSBL=ddr4 ./scripts/flash.sh pieces <partition> [piece]` — this writes one sparse piece per call, so
it can pick up where the last session stopped. `flash`, `pieces` and `resume` are all idempotent, and each sparse
piece only touches its own range, so a partition can be finished across as many sessions as it takes. When you're
done, `ONLY=toc1,boot1,rootfs1,boot2 ./scripts/flash.sh verify` should read `OK` on all four — `rootfs2` can stay
stock as a fallback, since `oem prep` already points the robot at slot 1.

**7. Reboot** (robot): `./scripts/flash.sh reboot`. On the UART you should see:

```
login[...]: root login on 'ttyS0'
 Athena Linux (r2416_release)
built with dustbuilder (https://builder.dontvacuum.me)
[root@r2416_release:~]#
```

That is a root shell on the serial console, which the stock firmware does not have.

**8. Valetudo.** On your home network, run `./scripts/valetudo-install.sh fetch` (the latest `valetudo-aarch64`, checked
against the release manifest). Then turn on the robot's Wi-Fi AP by holding its two outer buttons for 3 s, join the
AP from the Mac, and run `./scripts/valetudo-install.sh install`. It:

- backs up `/mnt/private` + `/mnt/misc` to `$DATA/backup/`,
- copies Valetudo to `/data/valetudo` and checks its sha256 on the robot,
- enables `/data/_root_postboot.sh` from dustbuilder's template,
- reboots.

Valetudo then answers on http://192.168.5.1.

The Mac cannot be on two Wi-Fi networks at once, which is why the download happens first.

**9. Home Wi-Fi.** Use Valetudo → Settings → Connectivity → Wi-Fi (2.4 GHz only). Alternatively, with the UART still
attached, run `./scripts/robot-wifi.sh`. It reads SSID and password from `$DATA/wifi.txt` (two lines, `chmod 600`)
and sets them through Valetudo's API from the root shell, without the credentials showing up in the UART log. Check
the result with `./scripts/robot-wifi.sh status`.

## Troubleshooting

The reasoning behind each of these is in [JOURNEY.md](JOURNEY.md); this is just the fix.

### The fsbl defaults to the wrong DRAM set

The job zip's `fsbl.bin` is DDR3-default; this robot is DDR4. Run `flash.sh probe` first and use **`FSBL=ddr4`** for
everything else if it comes back `verdict=default`.

### The eMMC write timeout

A bare `FAIL` (or a USB timeout) on `flash` usually means this — the UART shows:

```
[mmc]: mmc 2 data timeout 0 status 14
[mmc]: smc 2 err, cmd 25,  STO
[mmc]: mmc write failed
sparse: flash write failed
```

After it, the card refuses reads too (`cmd 18 RTO`), so nothing else works in that session — not `resume`, not even
`getvar config`. Power off and start a new FEL session. Then write fewer megabytes per session: `flash.sh pieces
<partition> [piece]` instead of a full `flash`. Stripping HS400/HS200/DDR from the payload's device tree does
**not** fix it — kept as a documented dead end in [`tools/payload-emmc-caps.sh`](tools/payload-emmc-caps.sh).

### A failed flash changes `getvar config`

Once the env and the toc1 backup have been written, the robot reports a different config, and `flash.sh` refuses to
run a job that doesn't match it. **Don't edit around that check** — build a new dustbuilder job for the new config.
`boot.img`, `toc1.img` and `fsbl.bin` come back identical to the old job's; only `rootfs.img` and `payload.bin`
differ (they contain your key and config).

### macOS serial ports reset to 9600

Running `stty -f PORT 115200` and `cat PORT` as separate commands captures at 9600 and gives you garbage.
[`scripts/uart.sh`](scripts/uart.sh) sets the speed and reads on the same open descriptor. The UART is output-only
on stock firmware — no U-Boot prompt, no login; the one stock route to a serial shell needs a USB stick with a key
signed by Dreame ([docs/uart-shell-root.md](docs/uart-shell-root.md)).

### busybox `stty -echo` crashes the robot's shell

It segfaults, and the login that respawns echoes your next line into the log. Use `read -s` instead to pass a
secret to the root shell (that's what `robot-wifi.sh` does).

## Recovery

- **FEL always works.** It is in the SoC's mask ROM and is selected by the button before the eMMC is read.
- The stage-1 samples cover everything the flash touches. `flash.sh prepare-restore` builds stock `boot1/rootfs1/boot2/rootfs2`
  from the decrypted samples, and `flash.sh restore [PART...]` writes them back and verifies them. Keep the eMMC
  timeout in mind here too.
- [`scripts/debug-readonly.sh`](scripts/debug-readonly.sh) is a post-mortem with no writes. It dumps eMMC window 0
  without `oem dust` and byte-diffs it against your pristine sample ([`tools/dumpdiff.py`](tools/dumpdiff.py)),
  including the decoded U-Boot env.

## Layout

| Path | What |
|---|---|
| `scripts/setup-mac.sh` | toolchain + stage1 package, all pinned |
| `scripts/samples.sh` | stage 1: config + 3 samples (read-only, resumable) |
| `scripts/test-download.sh` | Mac → robot `download` test to RAM, speed + `max-download-size` (no writes) |
| `scripts/flash.sh` | `prepare`, `probe`, `rehearse`, `flash`, `pieces`, `resume`, `verify`, `reboot`, `prepare-restore`, `restore` |
| `scripts/uart.sh` | UART capture at 115200 on macOS, logs to `$DATA/logs/` |
| `scripts/debug-readonly.sh` | post-mortem read-back without `oem dust` |
| `scripts/check-rooted.sh` | after reboot, over SSH: banner + md5 of the slots vs the images (`PARTS=` to limit) |
| `scripts/valetudo-install.sh` | `fetch` / `install` Valetudo over the robot's AP |
| `scripts/robot-wifi.sh` | join the robot to Wi-Fi through Valetudo's API over the UART |
| `tools/fbtool.c` | libusb fastboot client. Writes (`oem dust/prep`, `flash`, `reboot`) only with `FBTOOL_WRITE=1`; only `toc1/boot1/boot2/rootfs1/rootfs2`; no `erase` |
| `tools/fbsparse.cpp`, `tools/simgcheck.py` | split images like fastboot / check pieces independently |
| `tools/dustdecrypt.py`, `tools/verifyflash.py`, `tools/dumpdiff.py` | decrypt samples / `upload`, verify written ranges, diff dumps and env |
| `tools/fsblparams.py` | decode the fsbl's DRAM sets and tell which one the robot used |
| `tools/payload-emmc-caps.sh` | the device-tree patch that did not help |
| `tests/` | `test-flash-flow.sh` (flash.sh vs a mock fbtool, many scenarios) and `test-vs-fastboot.sh` (Google fastboot vs fbtool against a fake robot over TCP) |

Tests need `flash.sh prepare` to have been run: `bash tests/test-flash-flow.sh`, `bash tests/test-vs-fastboot.sh`
(`FASTBOOT=` points at Google platform-tools).

## Credits

[Valetudo](https://valetudo.cloud) (Sören Beye) and [dustbuilder](https://builder.dontvacuum.me) (Dennis Giese) do
the real work: the firmware, the payload and the guide.
[Max Ammann's write-up](https://maxammann.org/posts/2025/06/dreame-fel-mode/) explains the FEL payload and the
sample encryption. [linux-sunxi/sunxi-tools](https://github.com/linux-sunxi/sunxi-tools) provides `sunxi-fel`.
[Leo's notes on the L40 Ultra](https://leo.leung.xyz/wiki/Dreame_L40_Ultra) were a useful second source.
