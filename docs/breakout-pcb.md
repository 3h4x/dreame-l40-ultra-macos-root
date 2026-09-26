# Breakout PCB (FEL + UART)

The dustbuilder-style Valetudo breakout board used to put the robot into FEL and to tap its debug UART.

| | |
|---|---|
| Type | Valetudo rooting breakout ("SoC + MCU breakout", Dreame adapter) |
| Compatibility (from the listing) | Dreame D9/D9 Pro, D10s Pro/Plus, F9, L10 Pro, W10/W10 Pro, X40 Ultra/Master, **L40 Ultra**, Z10 Pro, L10s Ultra, Movo, Z500, S20 Ultra, P10 Pro Ultra … |
| Orientation | silk: *"This side towards front/top of robot"* — the left male pin strip mates to the robot |

## Connectors

- **Left male pin strip** — plugs into the robot (SoC side). *"This side towards front/top of robot."*
- **SoC Breakout** (top female 2.54 mm socket): `BSel · RX · TX · GND · ID · D+ · D- · VBUS` (OTG)
- **MCU Breakout** (bottom female socket): MCU-side signals (`… IO CLK …`) — not needed for FEL/flash.
- **FEL USB** (micro-USB) — data link to the Mac while in FEL / fastboot.
- **USB OTG** (USB-A) — OTG host port.
- **Boot Select** button + **SMA_BSN/VBUS** jumper — used for entering FEL.

## UART tap (for reading the sprite / boot console)

The SoC UART0 debug console (`console=ttyS0,115200`, `earlyprintk=sunxi-uart,0x05000000`) is broken out on the
**SoC Breakout** header as `RX` / `TX` / `GND`. It is a **female socket**, so **no soldering** — just insert wires.

**Adapter:** any 3.3 V USB-UART (FT232RL with the jumper set to **3.3 V**, or a CP2102 whose UART logic is 3.3 V).
⚠ 3.3 V logic only — 5 V can damage the SoC. Do **not** wire any VCC/5V/3V3 power line; the robot powers itself.

**Wires:** 3 × male-female dupont (male end into the breakout socket, female end onto the adapter's male pins).

| Adapter | → | Breakout SoC | note |
|---|---|---|---|
| `TXD` | → | `RX` | crossed |
| `RXD` | → | `TX` | crossed |
| `GND` | → | `GND` | common ground |

Leave `BSel`, `ID`, `D+`, `D-`, `VBUS`, and the adapter's `DTR/CTS/RTS/VCC` unconnected.

### Example adapter (FT232RL, USB-C)

- Voltage jumper: 3-pin header next to the FTDI chip, labelled `3.3V` on one side and `5V` on the other. The shunt
  sits on the `3.3V` side (the `5V` pin is left bare). Check this before every connection to the robot.
- Straight 6-pin header, order `DTR, RXD, TXD, VCC, CTS, GND`. With the pins pointing away from you and the chip
  facing up, `DTR` is at the end next to the `DTR` label and `GND` at the far end. The side rows of bare holes
  duplicate the same signals (`TXD`, `RXD`, `GND`, …) but hold no pins, so use the straight header.
- Wired as: GND (red) → breakout `GND`, TXD (orange) → breakout `RX`, RXD (yellow) → breakout `TX`. The boot log came through on the first try.
- macOS port: `/dev/cu.usbserial-<adapter serial>`. The FTDI driver is built in, no install needed.

## Capture on macOS (115200 8N1)

1. Plug the adapter into USB and find its port: `./scripts/uart.sh --list` (FT232RL/CP2102 show up as
   `/dev/cu.usbserial-*` / `/dev/cu.SLAB_USBtoUART`).
2. **Loopback test before touching the robot:** short the adapter's `TXD`↔`RXD`, run `./scripts/uart.sh` and
   `printf 'PING\r\n' > /dev/cu.usbserial-XXXX` in another terminal — `PING` must come back. Remove the short. (This
   passes at any baud as long as both ends match, so it does not prove the speed — see the note below.)
3. Log: `./scripts/uart.sh` → `$DATA/logs/uart-<ts>.log`, echoed to the screen, Ctrl-C to stop.

**macOS gotcha:** a serial port's settings reset to 9600 on last close, so `stty -f PORT 115200` followed by a
separate `cat PORT` reads at 9600 (a 115200 sender then shows up as high-bit garbage like `ff fe 80 …`).
`scripts/uart.sh` sets the speed and reads on the same open descriptor and prints the effective speed.

What this console shows (see README, *UART boot log*): SBOOT → BL31 → OP-TEE → U-Boot → kernel → full userspace. It
is **output-only** on the stock firmware: no U-Boot interrupt window, no serial login. During a flash it shows the
payload's real error (e.g. the eMMC write timeout), which USB hides behind a bare `FAIL`. After rooting, the
dustbuilder firmware runs a **root shell** on it.
