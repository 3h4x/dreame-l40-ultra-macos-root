// Fastboot client over libusb for the Dreame fastboot gadget on macOS, where Google's fastboot
// cannot see it. Read-only: devices, getvar, oem stage1|stage2, upload (robot -> Mac, get_staged),
// download (Mac -> robot, staged in the robot's RAM only).
// Writing, refused unless FBTOOL_WRITE=1: oem dust CHECK, oem prep, flash PART FILE (Google fastboot's getvar
// prelude + download + flash:PART, PART limited to the five partitions of the Valetudo guide), reboot. No erase.
// FBTOOL_TCP=host:port swaps USB for fastboot's TCP transport (as in `fastboot -s tcp:`), used only by
// tests/fake-robot.py so the same client code can be compared with Google's fastboot.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <libusb.h>

#define CHUNK (64 * 1024)   // larger bulk transfers EIO on this gadget under macOS
#define CMD_TIMEOUT 30000
#define DATA_TIMEOUT 120000

static libusb_context *ctx;
static libusb_device_handle *h;
static int iface = -1;
static unsigned char ep_in, ep_out;

static const char *tcp_target;   // FBTOOL_TCP, or NULL for USB
static int tcp_fd = -1;
static unsigned long long tcp_left;   // bytes of the current incoming TCP message not read yet

static int tcp_io(int fd, void *buf, size_t len, int sending) {
    unsigned char *p = buf;
    while (len > 0) {
        ssize_t n = sending ? send(fd, p, len, 0) : recv(fd, p, len, 0);
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int tcp_connect(void) {
    char host[64];
    const char *colon = strrchr(tcp_target, ':');
    if (!colon || colon - tcp_target >= (long)sizeof host) return 0;
    memcpy(host, tcp_target, colon - tcp_target);
    host[colon - tcp_target] = 0;
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((unsigned short)atoi(colon + 1))};
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) return 0;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct timeval tv = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char hs[4];
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0 || tcp_io(fd, "FB01", 4, 1) || tcp_io(fd, hs, 4, 0)
        || memcmp(hs, "FB", 2)) {
        close(fd);
        return 0;
    }
    tcp_fd = fd;
    ep_in = 0x81;   // only to tell reads from writes in bulk()
    ep_out = 0x01;
    return 1;
}

static int find_fastboot(void) {
    if (tcp_target) return tcp_connect();
    libusb_device **list;
    ssize_t n = libusb_get_device_list(ctx, &list);
    int found = 0;
    for (ssize_t i = 0; i < n && !found; i++) {
        struct libusb_config_descriptor *cfg;
        if (libusb_get_config_descriptor(list[i], 0, &cfg) != 0) continue;
        for (int j = 0; j < cfg->bNumInterfaces && !found; j++) {
            const struct libusb_interface_descriptor *d = &cfg->interface[j].altsetting[0];
            if (d->bInterfaceClass != 0xff || d->bInterfaceSubClass != 0x42 || d->bInterfaceProtocol != 0x03) continue;
            ep_in = ep_out = 0;
            for (int k = 0; k < d->bNumEndpoints; k++) {
                const struct libusb_endpoint_descriptor *e = &d->endpoint[k];
                if ((e->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_BULK) continue;
                if (e->bEndpointAddress & 0x80) ep_in = e->bEndpointAddress; else ep_out = e->bEndpointAddress;
            }
            if (ep_in && ep_out && libusb_open(list[i], &h) == 0) { iface = d->bInterfaceNumber; found = 1; }
        }
        libusb_free_config_descriptor(cfg);
    }
    libusb_free_device_list(list, 1);
    return found;
}

static int acquire(void) {
    for (int tries = 0; tries < 32; tries++) {
        if (tcp_target && find_fastboot()) return 0;
        if (!tcp_target && find_fastboot()) {
            int cur = 0;
            libusb_get_configuration(h, &cur);
            if (cur != 1) libusb_set_configuration(h, 1);
            if (libusb_claim_interface(h, iface) == 0) return 0;
            libusb_close(h); h = NULL;
        }
        usleep(250000);
    }
    fprintf(stderr, "FAILED no fastboot device\n");
    return -1;
}

// TCP framing: every message is an 8-byte big-endian length plus data; a read returns at most what is left of the
// current message, like a bulk IN transfer returns at most one packet's worth.
static int tcp_bulk(int out, unsigned char *buf, int len, int timeout) {
    struct timeval tv = {.tv_sec = timeout / 1000, .tv_usec = (timeout % 1000) * 1000};
    setsockopt(tcp_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    unsigned char hdr[8];
    if (out) {
        for (int i = 0; i < 8; i++) hdr[i] = (unsigned char)((unsigned long long)len >> (56 - 8 * i));
        if (tcp_io(tcp_fd, hdr, 8, 1) || tcp_io(tcp_fd, buf, (size_t)len, 1)) goto fail;
        return len;
    }
    if (tcp_left == 0) {
        if (tcp_io(tcp_fd, hdr, 8, 0)) goto fail;
        for (int i = 0; i < 8; i++) tcp_left = (tcp_left << 8) | hdr[i];
        if (tcp_left == 0) return 0;
    }
    int n = tcp_left < (unsigned long long)len ? (int)tcp_left : len;
    if (tcp_io(tcp_fd, buf, (size_t)n, 0)) goto fail;
    tcp_left -= (unsigned long long)n;
    return n;
fail:
    fprintf(stderr, "FAILED tcp\n");
    return -1;
}

static int bulk(unsigned char ep, unsigned char *buf, int len, int timeout) {
    if (tcp_target) return tcp_bulk(ep == ep_out, buf, len, timeout);
    int got = 0;
    int r = libusb_bulk_transfer(h, ep, buf, len, &got, timeout);
    if (r != 0) { fprintf(stderr, "FAILED usb: %s\n", libusb_error_name(r)); return -1; }
    return got;
}

// Reads until a terminal response; prints INFO lines. Returns the response in resp.
static int read_resp(char *resp, int timeout) {
    for (;;) {
        unsigned char buf[257];
        int n = bulk(ep_in, buf, 256, timeout);
        if (n < 0) return -1;
        if (n == 0) continue;
        buf[n] = 0;
        if (!memcmp(buf, "INFO", 4)) { fprintf(stderr, "(bootloader) %s\n", buf + 4); continue; }
        if (!memcmp(buf, "TEXT", 4)) { fprintf(stderr, "%s", buf + 4); continue; }
        strcpy(resp, (char *)buf);
        return 0;
    }
}

static int command(const char *cmd, char *resp, int timeout) {
    if (bulk(ep_out, (unsigned char *)cmd, (int)strlen(cmd), timeout) < 0) return -1;
    return read_resp(resp, timeout);
}

static void progress(unsigned long done, unsigned long size, unsigned long *last) {
    if (done - *last >= 50UL << 20) { fprintf(stderr, "  %lu/%lu MB\n", done >> 20, size >> 20); *last = done; }
}

static int upload(const char *path) {
    char resp[257];
    if (command("upload", resp, CMD_TIMEOUT) < 0) return 1;
    if (memcmp(resp, "DATA", 4)) { fprintf(stderr, "FAILED upload rejected: %s\n", resp); return 1; }
    unsigned long size = strtoul(resp + 4, NULL, 16);
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return 1; }
    unsigned char *buf = malloc(CHUNK);
    unsigned long got = 0, last = 0;
    while (got < size) {
        unsigned long want = size - got < CHUNK ? size - got : CHUNK;
        int n = bulk(ep_in, buf, (int)want, DATA_TIMEOUT);
        if (n < 0) { fclose(f); free(buf); return 1; }
        fwrite(buf, 1, n, f);
        got += n;
        progress(got, size, &last);
    }
    free(buf);
    fclose(f);
    if (read_resp(resp, DATA_TIMEOUT) < 0) return 1;
    if (memcmp(resp, "OKAY", 4)) { fprintf(stderr, "FAILED upload: %s\n", resp); return 1; }
    return 0;
}

// Stages a file in the robot's RAM (fastboot "download"). Nothing is written to flash.
static int download(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) { perror(path); return 1; }
    if (st.st_size <= 0 || st.st_size > 0xffffffffL) { fprintf(stderr, "FAILED bad size %lld\n", (long long)st.st_size); return 1; }
    unsigned long size = (unsigned long)st.st_size;
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }
    char resp[257], cmd[32];
    snprintf(cmd, sizeof cmd, "download:%08lx", size);
    if (command(cmd, resp, CMD_TIMEOUT) < 0) { fclose(f); return 1; }
    if (memcmp(resp, "DATA", 4)) { fprintf(stderr, "FAILED download rejected: %s\n", resp); fclose(f); return 1; }
    if (strtoul(resp + 4, NULL, 16) != size) { fprintf(stderr, "FAILED download: robot expects %s, file is %08lx\n", resp + 4, size); fclose(f); return 1; }
    unsigned char *buf = malloc(CHUNK);
    unsigned long sent = 0, last = 0;
    while (sent < size) {
        size_t want = size - sent < CHUNK ? size - sent : CHUNK;
        if (fread(buf, 1, want, f) != want) { perror(path); fclose(f); free(buf); return 1; }
        int n = bulk(ep_out, buf, (int)want, DATA_TIMEOUT);
        if (n != (int)want) { if (n >= 0) fprintf(stderr, "FAILED short write %d/%zu\n", n, want); fclose(f); free(buf); return 1; }
        sent += n;
        progress(sent, size, &last);
    }
    free(buf);
    fclose(f);
    if (read_resp(resp, DATA_TIMEOUT) < 0) return 1;
    if (memcmp(resp, "OKAY", 4)) { fprintf(stderr, "FAILED download: %s\n", resp); return 1; }
    return 0;
}

static const char *const partitions[] = {"toc1", "boot1", "boot2", "rootfs1", "rootfs2", NULL};

static int known_partition(const char *p) {
    for (int i = 0; partitions[i]; i++) if (!strcmp(p, partitions[i])) return 1;
    return 0;
}

static int is_check_value(const char *v) {
    if (strlen(v) != 8) return 0;
    for (int i = 0; i < 8; i++) if (!strchr("0123456789abcdef", v[i])) return 0;
    return 1;
}

// Returns 1 for the commands that change the robot, 0 for read-only ones, -1 for anything not allowed.
static int classify(int argc, char **argv) {
    const char *c = argv[1];
    if (!strcmp(c, "devices") && argc == 2) return 0;
    if ((!strcmp(c, "getvar") || !strcmp(c, "upload") || !strcmp(c, "download")) && argc == 3) return 0;
    if (!strcmp(c, "oem") && argc == 3 && (!strcmp(argv[2], "stage1") || !strcmp(argv[2], "stage2"))) return 0;
    if (!strcmp(c, "oem") && argc == 3 && !strcmp(argv[2], "prep")) return 1;
    if (!strcmp(c, "oem") && argc == 4 && !strcmp(argv[2], "dust") && is_check_value(argv[3])) return 1;
    if (!strcmp(c, "flash") && argc >= 4 && known_partition(argv[2])) return 1;
    if (!strcmp(c, "reboot") && argc == 2) return 1;
    return -1;
}

// The read-only prelude Google's fastboot 37.0.1 sends before every flash (captured against tests/fake-robot.py),
// so the robot sees the same command stream as the guide's. Answers are ignored: the payload says "not supported".
static const char *const flash_prelude[] = {"is-userspace", "has-slot:", "is-logical:", "is-logical:",
                                            "partition-size:", "is-logical:", "max-download-size", NULL};

// One partition, one or more files (the sparse pieces of a big image): the prelude once, then download + flash:PART
// per file — what Google's fastboot does for `fastboot flash rootfs1 rootfs.img` after splitting it.
static int flash(const char *part, char **paths, int n) {
    char resp[257], cmd[64];
    for (int i = 0; flash_prelude[i]; i++) {
        const char *v = flash_prelude[i];
        snprintf(cmd, sizeof cmd, "getvar:%s%s", v, v[strlen(v) - 1] == ':' ? part : "");
        if (command(cmd, resp, CMD_TIMEOUT) < 0) return 1;
    }
    for (int i = 0; i < n; i++) {
        if (n > 1) fprintf(stderr, "  %s %d/%d\n", part, i + 1, n);
        if (download(paths[i])) return 1;
        snprintf(cmd, sizeof cmd, "flash:%s", part);
        if (command(cmd, resp, DATA_TIMEOUT) < 0) return 1;
        if (memcmp(resp, "OKAY", 4)) { fprintf(stderr, "FAILED flash:%s: %s\n", part, resp); return 1; }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: fbtool devices | getvar VAR | oem stage1|stage2 | upload FILE | download FILE\n"
                        "       FBTOOL_WRITE=1 fbtool oem dust CHECK | oem prep | flash toc1|boot1|boot2|rootfs1|rootfs2 FILE... | reboot\n");
        return 2;
    }
    int writes = classify(argc, argv);
    if (writes < 0) {
        fprintf(stderr, "command not allowed (see usage; there is no erase, and only the guide's partitions can be flashed)\n");
        return 2;
    }
    const char *allow = getenv("FBTOOL_WRITE");
    if (writes && !(allow && !strcmp(allow, "1"))) {
        fprintf(stderr, "refused: '%s' changes the robot; set FBTOOL_WRITE=1 to allow it\n", argv[1]);
        return 3;
    }
    tcp_target = getenv("FBTOOL_TCP");
    if (!tcp_target) libusb_init(&ctx);
    if (!strcmp(argv[1], "devices")) { int ok = find_fastboot(); if (ok) printf("libusb\tfastboot\n"); return ok ? 0 : 1; }
    if (acquire() < 0) return 1;
    char resp[257], cmd[128];
    int rc = 1;
    if (!strcmp(argv[1], "getvar") && argc == 3) {
        snprintf(cmd, sizeof cmd, "getvar:%s", argv[2]);
        if (command(cmd, resp, CMD_TIMEOUT) == 0 && !memcmp(resp, "OKAY", 4)) { printf("%s: %s\n", argv[2], resp + 4); rc = 0; }
        else fprintf(stderr, "FAILED getvar: %s\n", resp);
    } else if (!strcmp(argv[1], "oem")) {
        if (argc == 4) snprintf(cmd, sizeof cmd, "oem %s %s", argv[2], argv[3]);
        else snprintf(cmd, sizeof cmd, "oem %s", argv[2]);
        if (command(cmd, resp, DATA_TIMEOUT) == 0 && !memcmp(resp, "OKAY", 4)) { printf("OKAY\n"); rc = 0; }
        else fprintf(stderr, "FAILED %s: %s\n", cmd, resp);
    } else if (!strcmp(argv[1], "upload")) {
        rc = upload(argv[2]);
        if (rc == 0) printf("OKAY\n");
    } else if (!strcmp(argv[1], "download")) {
        rc = download(argv[2]);
        if (rc == 0) printf("OKAY\n");
    } else if (!strcmp(argv[1], "flash")) {
        rc = flash(argv[2], argv + 3, argc - 3);
        if (rc == 0) printf("OKAY\n");
    } else if (!strcmp(argv[1], "reboot")) {
        // Once the command is sent the robot may drop off the bus before answering; that means it was taken.
        if (bulk(ep_out, (unsigned char *)"reboot", 6, CMD_TIMEOUT) < 0) fprintf(stderr, "FAILED reboot not sent\n");
        else if (read_resp(resp, CMD_TIMEOUT) == 0 && memcmp(resp, "OKAY", 4)) fprintf(stderr, "FAILED reboot: %s\n", resp);
        else { printf("OKAY\n"); rc = 0; }
    }
    if (tcp_target) { close(tcp_fd); return rc; }
    libusb_release_interface(h, iface);
    libusb_close(h);
    libusb_exit(ctx);
    return rc;
}
