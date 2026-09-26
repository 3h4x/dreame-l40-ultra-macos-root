// Splits an image into the sparse pieces fastboot 34.0.5 (Debian 13, the version the Valetudo guide tested) would
// send for it when it is larger than max-download-size. Same libsparse, same calls as fastboot.cpp:
// load_sparse_files() = sparse_file_import_auto(fd, false, true) + sparse_file_resparse(s, max), and each piece is
// streamed with sparse_file_callback(s, true, false) (sparse, no CRC), here into PREFIX.NN.simg.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <sparse/sparse.h>

static int write_cb(void* priv, const void* data, size_t len) {
    int fd = *static_cast<int*>(priv);
    if (!data) {  // fastboot's SparseWriteCallback never gets NULL for sparse output; keep it strict
        fprintf(stderr, "unexpected skip in sparse output\n");
        return -1;
    }
    const char* p = static_cast<const char*>(data);
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) { perror("write"); return -1; }
        p += n;
        len -= n;
    }
    return 0;
}

int main(int argc, char** argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: fbsparse MAX_BYTES IMAGE PREFIX   (writes PREFIX.NN.simg)\n");
        return 2;
    }
    long long max = strtoll(argv[1], nullptr, 0);
    if (max <= 0 || max > 0xffffffffLL) { fprintf(stderr, "bad max %s\n", argv[1]); return 2; }
    int in = open(argv[2], O_RDONLY);
    if (in < 0) { perror(argv[2]); return 1; }

    sparse_file* s = sparse_file_import_auto(in, false, true);
    if (!s) { fprintf(stderr, "cannot sparse read %s\n", argv[2]); return 1; }
    int files = sparse_file_resparse(s, max, nullptr, 0);
    if (files < 0) { fprintf(stderr, "failed to compute resparse boundaries\n"); return 1; }
    sparse_file** out = static_cast<sparse_file**>(calloc(files, sizeof(*out)));
    if (sparse_file_resparse(s, max, out, files) < 0) { fprintf(stderr, "failed to resparse\n"); return 1; }

    int rc = 0;
    for (int i = 0; i < files && rc == 0; i++) {
        char path[4096];
        snprintf(path, sizeof path, "%s.%02d.simg", argv[3], i + 1);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { perror(path); rc = 1; break; }
        int64_t len = sparse_file_len(out[i], true, false);
        if (len < 0 || len > max) { fprintf(stderr, "%s: bad length %lld\n", path, (long long)len); rc = 1; }
        else if (sparse_file_callback(out[i], true, false, write_cb, &fd) < 0) { fprintf(stderr, "%s: write failed\n", path); rc = 1; }
        else printf("%s %lld\n", path, (long long)len);
        close(fd);
    }
    for (int i = 0; i < files; i++) sparse_file_destroy(out[i]);
    free(out);
    sparse_file_destroy(s);
    close(in);
    return rc;
}
