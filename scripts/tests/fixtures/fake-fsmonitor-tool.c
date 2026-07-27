#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *program_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash == NULL ? path : slash + 1;
}

static const char *pid_argument(int argc, char **argv) {
    for (int index = 1; index + 1 < argc; ++index) {
        if (strcmp(argv[index], "-p") == 0) {
            return argv[index + 1];
        }
    }
    return "";
}

static int print_file(const char *prefix, const char *pid) {
    const char *spool = getenv("HARNESS_FSMONITOR_TEST_SPOOL");
    if (spool == NULL) {
        return 2;
    }
    char path[4096];
    int length = snprintf(path, sizeof(path), "%s/%s-%s.txt", spool, prefix, pid);
    if (length < 0 || (size_t)length >= sizeof(path)) {
        return 2;
    }
    FILE *input = fopen(path, "r");
    if (input == NULL) {
        return 0;
    }
    char buffer[8192];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), input)) > 0) {
        fwrite(buffer, 1, count, stdout);
    }
    fclose(input);
    return 0;
}

int main(int argc, char **argv) {
    const char *name = program_name(argv[0]);
    if (strcmp(name, "pgrep") == 0) {
        const char *pids = getenv("HARNESS_FSMONITOR_TEST_PIDS");
        if (pids != NULL && pids[0] != '\0') {
            printf("%s\n", pids);
        }
        return 0;
    }
    if (strcmp(name, "lsof") == 0) {
        return print_file("lsof", pid_argument(argc, argv));
    }
    if (strcmp(name, "ps") == 0) {
        return print_file("ps-etime", pid_argument(argc, argv));
    }
    return 0;
}
