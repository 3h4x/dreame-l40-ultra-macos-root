# How it went: mistakes, dead ends and what finally worked

This is a diary of rooting my Dreame L40 Ultra from a Mac, cleaned of anything that would identify this specific
unit: serial, config values, job ids, MAC and network details. It's here because the failures taught more than the
successes did, and most of them will happen to the next person too.

I stuck to a few rules the whole way through: read-only checks and recon before any write, a no-write rehearsal for
every write path (`probe`, `rehearse`, `test-download.sh`, `debug-readonly.sh`, plus a mock/fake robot in `tests/`),
and never trusting an `OKAY` from the payload until I'd read the eMMC back and compared it. When a guard stopped a
run, I treated the guard as right until I could prove otherwise.

## Getting a working host

Google `fastboot` doesn't work on macOS with this payload. The gadget has device class `0xff`, macOS won't
configure it, and `fastboot devices` stays empty. Forcing configuration 1 gets small commands through, but a 400 MB
upload stalls at zero bytes. I ended up writing `tools/fbtool.c` — about 300 lines of libusb with 64 KiB transfers
streamed to disk — which pulls 399 MB in 30 s.

A Raspberry Pi 1 isn't a usable host either: Debian's current `fastboot` is built for ARMv7 and dies with `SIGILL`
on the Pi's ARMv6, and an older Raspbian build that does run buffers the whole 400 MB upload in RAM (the Pi only has
~430 MB), so it hung and rebooted mid-transfer. Its USB hub, shared with Ethernet, also reset once on hot-plug.

The usable window starts at the button press, not the first command — the robot's MCU cuts power after ~210 s,
leaving ~160–180 s per session, so the scripts start the moment FEL appears. `getvar config` has to be the first
command in every session or the payload just answers `FAIL you need to run "fastboot getvar config" first`.

Stage 1 — config plus three ~400 MB samples — ran in 61 s at 13 MB/s, and I sent those to dustbuilder to build the
job. Following Max Ammann's write-up, `tools/dustdecrypt.py` decrypts those samples: they're the first ~1.2 GB of
the eMMC, XOR'd with a key from a fixed seed, and they contain the GPT, both bootloader copies, env, both firmware
slots and the calibration partitions. That decrypted copy is what made every later decision safe — it wasn't just
an entry ticket for dustbuilder, it was my backup.

I later made `fbtool` behave exactly like Google's fastboot: a differential test (`tests/test-vs-fastboot.sh`) runs
the same sequence once with each tool against a fake robot over TCP and diffs every command and every downloaded
byte, including the getvar prelude before each flash (which fbtool wasn't sending). It turned out not to matter in
practice, but I wanted to know that rather than assume it.

## The DDR mismatch and the first flash

The job's `fsbl.bin` turned out to be byte-identical to the stage-1 `fsbl_ddr3.bin`. Running `flash.sh probe`
against the stage-1 `fsbl_ddr4.bin` alone and reading back from SRAM showed it fell back to its header default —
DDR4 at 792 MHz — meaning the DDR3-default `fsbl.bin` would have set up DDR3 timings on DDR4 memory. I added
`FSBL=ddr4` to fix that. Confirmation came later: dustbuilder itself publishes `dust-livesuit-mr813-ddr4.img` for
this SoC, and the payload's own U-Boot prints `DRAM: 512 MiB` after training (the how-to assumes 1 GB; this unit
has 512 MB).

Two rehearsals passed clean — downloads to RAM only, no writes, read back and compared against the images. Then
the first real flash stopped at `boot1`: `getvar config`, `oem dust` and `oem prep` all came back `OKAY`, `flash
toc1` came back `OKAY` (same bytes the robot already had), and `flash boot1` accepted the download and then failed
bare, about 6 seconds later.

A read-only post-mortem (`debug-readonly.sh`, then `dumpdiff.py` against the pristine sample) showed the `boot1`
write had never actually happened — it was still byte-identical to factory. But `oem prep` had already rewritten
the env (`boot_partition` boot2→boot1, `root_partition` rootfs2→rootfs1, plus a memory-write root patch before
`bootm` — that's the actual rooting step, and it now expected the new image in slot 1), and the toc1 backup copy
had been overwritten by the main one. Everything else, including slot 2, was untouched.

I got a couple of things wrong reading that result. I said the robot "no longer boots" because the next power-on
landed in FEL — it landed in FEL because I was holding the boot-select button, and a UART log the next day showed
a full boot. I also called the `boot1` failure "deterministic" after a single attempt, when it turned out to be an
eMMC issue that showed up again later for a different reason. And after `oem dust` runs, `upload` output stops
decrypting with the stage-1 key for the rest of that session, so a read-back taken right after a failure in the
same session tells you nothing — only a fresh session without `oem dust` gives a reliable read-back.

## UART, and the real cause

An FT232RL at 3.3 V on the breakout's SoC header needs no soldering — TX→RX, RX→TX, GND→GND, never VCC. My first
capture was garbage because macOS resets a serial port to 9600 baud on last close, so `stty` and `cat` run as
separate commands ended up at different speeds while a loopback test passed regardless. `uart.sh` now sets the
speed and reads on the same descriptor.

On stock firmware the UART is output-only — no U-Boot prompt, no getty. The one path to a serial shell
(`mount_partition.sh` on USB insert) wants a key signed by Dreame, and I didn't try to get around that; the UART
was still worth wiring up because it shows everything the payload hides behind a bare `FAIL`.

After the env and toc1-backup writes, the robot reported a different config every session, and `flash.sh`'s own
guard against `getvar config` stopped the first retry — the job was built for a config that no longer existed, so I
needed a new one from dustbuilder. Its `boot.img`, `toc1.img` and `fsbl.bin` came back identical to the old job's;
`rootfs.img` and `payload.bin` differed. Probe and rehearse passed clean.

With UART attached this time, the retry got `toc1` OKAY and `boot1` OKAY — the step that failed before — then
`rootfs1` stopped after two pieces with an eMMC multi-block write timeout on the console (`mmc 2 data timeout`,
`cmd 25 STO`, `mmc write failed`, `sparse: flash write failed`). Afterwards even reads failed with `cmd 18 RTO`, so
a `resume` in the same session got stopped by the config check because the robot couldn't read its own config back.
Over USB the same thing had just looked like a USB timeout — without the UART there was no way to tell the
difference.

One fix I tried didn't work: the payload's U-Boot device tree allows HS400/HS200/DDR modes on the eMMC, so I
stripped those, touching only the device-tree bytes (the payload has no checksum). It booted fine and still tuned
to HS400 anyway — in FEL the tuning walks its own list regardless of what the device tree says. That attempt is
kept as a documented dead end in `tools/payload-emmc-caps.sh`.

What actually worked was fewer megabytes per session — the timeout showed up at roughly 80–100 MB of writes
regardless of pauses in between, but a power cycle reset it. So: session one wrote `rootfs1` pieces 1–3 clean and
failed on piece 4; a fresh FEL session wrote just piece 4; and the read-back after that showed `toc1`, `boot1`,
`rootfs1` and `boot2` all identical to the images, with `rootfs2` deliberately left stock as a fallback.
`flash.sh reboot` brought up `root login on 'ttyS0'`, `built with dustbuilder`, and a root prompt.

## Valetudo, and one more mistake

The Mac can only be on one Wi-Fi network at a time, so I downloaded the Valetudo binary and checked it against the
release manifest before joining the robot's AP. From there one script backed up `/mnt/private` and `/mnt/misc`,
copied the binary, checked its sha256 on the robot, enabled the postboot hook, and rebooted — Valetudo recognised
the model and its capabilities, camera stream included.

Getting the robot onto the home Wi-Fi from the root shell is where I made my last mistake: I piped credentials in
after running `stty -echo`, and busybox's `stty` segfaulted and killed the shell. The login that respawned then
echoed the next line — the base64'd SSID and password — straight into the UART log. I scrubbed the log immediately;
`robot-wifi.sh` now uses `read -s`, which this busybox handles fine. After that the robot joined the 2.4 GHz
network and both Valetudo and SSH were reachable from the Mac.
