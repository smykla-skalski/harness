#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TAIL_SIZE 256
#define VERSION_MARKER "HARNESS_FAKE_VERSION="

static const char *program_name(const char *path) {
    const char *separator = strrchr(path, '/');
    return separator == NULL ? path : separator + 1;
}

static int read_version(const char *path, char *version, size_t capacity) {
    char tail[TAIL_SIZE + 1];
    FILE *file = fopen(path, "rb");
    long size;
    size_t count;
    size_t index;
    size_t marker_length = strlen(VERSION_MARKER);
    size_t version_length;
    char *marker;

    if (file == NULL || fseek(file, 0, SEEK_END) != 0) {
        return 1;
    }
    size = ftell(file);
    if (size < 0 || fseek(file, size > TAIL_SIZE ? size - TAIL_SIZE : 0, SEEK_SET) != 0) {
        fclose(file);
        return 1;
    }
    count = fread(tail, 1, TAIL_SIZE, file);
    fclose(file);
    tail[count] = '\0';
    marker = NULL;
    for (index = 0; index + marker_length <= count; index++) {
        if (memcmp(tail + index, VERSION_MARKER, marker_length) == 0) {
            marker = tail + index + marker_length;
        }
    }
    if (marker == NULL) {
        return 1;
    }
    version_length = 0;
    while (marker + version_length < tail + count
           && marker[version_length] != '\r'
           && marker[version_length] != '\n') {
        version_length++;
    }
    if (version_length == 0 || version_length >= capacity) {
        return 1;
    }
    memcpy(version, marker, version_length);
    version[version_length] = '\0';
    return 0;
}

int main(int argc, char **argv) {
    const char *name = program_name(argv[0]);
    const char *argument = argc > 1 ? argv[1] : "";
    char version[64];

    if (strcmp(argument, "--version") == 0) {
        if (read_version(argv[0], version, sizeof(version)) != 0) {
            return 2;
        }
        printf("%s %s\n", name, version);
    } else if (strcmp(argument, "--probe") == 0) {
        if (strcmp(name, "harness-codex-acp") != 0
            && strcmp(name, "harness-openrouter-agent") != 0) {
            return 2;
        }
        printf("%s\n", name);
    } else if (strcmp(argument, "--help") == 0) {
        printf("%s\n", strcmp(name, "harness") == 0 ? "Harness CLI" : name);
    }
    return 0;
}
