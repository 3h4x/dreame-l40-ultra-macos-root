# Why there is no "UART shell" route on a stock L40 Ultra

Some older Dreame robots can be rooted from a serial console: a `mdev` rule starts a login on the debug UART when a
USB stick is plugged in, and the root password is derived from the serial number (dustbuilder FAQ). That would allow
flashing through the robot's own OTA updater (the `*_fw.tar.gz` from dustbuilder contains an `install.sh` for it),
without the FEL payload.

On the L40 Ultra's stock firmware this route is closed. Checked offline in the stock `rootfs` (decrypted from the
stage-1 samples):

- `/etc/inittab` has no getty on the serial port.
- The only path to one, `/usr/bin/mount_partition.sh` (run by `mdev` for USB storage), starts it only if the stick
  carries a key that verifies against Dreame's `/etc/UART_Key_pub.pem`. Nobody but Dreame can make such a key, and
  this repo does not try to get around it.
- A UART capture of a normal boot confirms it: SBOOT → BL31 → OP-TEE → U-Boot (no autoboot prompt) → kernel →
  userspace, and no login anywhere.

[Leo's notes](https://leo.leung.xyz/wiki/Dreame_L40_Ultra) say the same: *the UART shell method is not available for
this model due to secure boot*.

The UART is still worth wiring up: it shows the payload's real errors during a flash, and after rooting the dustbuilder
firmware runs a root shell on it (the password from the dustbuilder FAQ applies there, but it logs in by itself).
