#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *tool_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash == NULL ? path : slash + 1;
}

static void write_arguments(FILE *stream, int argc, char **argv, int start) {
    for (int index = start; index < argc; index += 1) {
        if (index > start) {
            fputc(' ', stream);
        }
        fputs(argv[index], stream);
    }
    fputc('\n', stream);
}

int main(int argc, char **argv) {
    const char *log_path = getenv("HARNESS_MONITOR_TEST_TOOL_LOG");
    if (log_path == NULL) {
        fputs("HARNESS_MONITOR_TEST_TOOL_LOG is required\n", stderr);
        return 64;
    }
    FILE *log = fopen(log_path, "a");
    if (log == NULL) {
        perror("open tool log");
        return 74;
    }

    int argument_start = 1;
    if (strcmp(tool_name(argv[0]), "tuist") == 0) {
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd)) == NULL) {
            perror("getcwd");
            fclose(log);
            return 74;
        }
        fprintf(log, "TUIST_PWD=%s\nTUIST=", cwd);
        write_arguments(log, argc, argv, 1);
        if (argc < 2 || strcmp(argv[1], "xcodebuild") != 0) {
            fclose(log);
            fputs("unexpected tuist subcommand\n", stderr);
            return 64;
        }
        argument_start = 2;
    }

    fputs("XCODEBUILD=", log);
    write_arguments(log, argc, argv, argument_start);
    fclose(log);

    const char *fail = getenv("FAKE_XCODEBUILD_FAIL");
    if (fail != NULL && strcmp(fail, "1") == 0) {
        fputs("/tmp/Fake.swift:1:1: error: synthetic failure\n", stdout);
        return 65;
    }
    return 0;
}
