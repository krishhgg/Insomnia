// Test-only. Linked into the test bundle, so this constructor runs when the
// bundle loads, before XCTest discovers a single test and whatever filter
// the run uses. Log.append and SessionManager.live resolve INSOMNIA_HOME
// at call time and fall back to the real ~/Library when it is unset; with
// the variable set here, no test, filtered or not, can write there.
//
// The directory goes in TMPDIR when the run sets it, so a runner that points
// TMPDIR at its own folder finds the home there. Without TMPDIR it goes in
// Darwin's per-user temp directory, then /tmp. Fixtures make their files in
// the same parent (insomnia_test_home_temp_dir), since Foundation's
// temporaryDirectory is Darwin's per-user one whatever TMPDIR says.
// The parent must be an existing directory, given as an absolute path, that
// this user owns and no one else can write to, or a sticky directory root
// owns, as /tmp is. Any other parent stops the bundle: a TMPDIR the run set
// is never swapped for another folder. The directory is removed when the
// process exits normally, and only if the path still names the directory
// made here.

#include "InsomniaTestHome.h"

#include <removefile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *const kKey = "INSOMNIA_HOME";
static char g_root[1024];
static char g_tmp[1024];
static int g_have_root = 0;
static pid_t g_owner = 0;
static dev_t g_dev = 0;
static ino_t g_ino = 0;

const char *insomnia_test_home_key(void) { return kKey; }

const char *insomnia_test_home_root(void) { return g_have_root ? g_root : NULL; }

const char *insomnia_test_home_temp_dir(void) { return g_have_root ? g_tmp : NULL; }

static void remove_root(void) {
    // Not in a forked child; only the process that made the directory removes it.
    if (!g_have_root || getpid() != g_owner) return;
    struct stat st;
    if (lstat(g_root, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_dev != g_dev || st.st_ino != g_ino) {
        fprintf(stderr, "InsomniaTestHome: %s is no longer the directory this process made; leaving it\n", g_root);
        return;
    }
    if (removefile(g_root, NULL, REMOVEFILE_RECURSIVE) != 0) perror("InsomniaTestHome: removefile");
}

static void refuse(const char *why, const char *path) {
    fprintf(stderr, "InsomniaTestHome: %s: %s\n", why, path);
    fprintf(stderr, "InsomniaTestHome: refusing to run tests against the real ~/Library\n");
    abort();
}

// Why `st`, the parent's stat, rules it out, or NULL when the home may go there.
static const char *parent_problem(const struct stat *st) {
    if (!S_ISDIR(st->st_mode)) return "not a directory";
    if (st->st_uid == getuid()) {
        if ((st->st_mode & (S_IWGRP | S_IWOTH)) != 0 && (st->st_mode & S_ISVTX) == 0)
            return "others can write to it and it is not sticky";
        return NULL;
    }
    if (st->st_uid == 0 && (st->st_mode & S_ISVTX) != 0) return NULL;
    return "owned by another user";
}

__attribute__((constructor))
static void insomnia_test_home_install(void) {
    char tmp[1024];
    const char *env = getenv("TMPDIR");
    if (env && *env) {
        if (snprintf(tmp, sizeof tmp, "%s", env) >= (int)sizeof tmp) refuse("TMPDIR is too long", env);
    } else {
        size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, sizeof tmp);
        if (n == 0 || n > sizeof tmp) snprintf(tmp, sizeof tmp, "%s", "/tmp/");
    }
    size_t len = strlen(tmp);
    while (len > 1 && tmp[len - 1] == '/') tmp[--len] = '\0';
    if (tmp[0] != '/') refuse("the temp directory is not an absolute path", tmp);

    struct stat parent;
    if (stat(tmp, &parent) != 0) {
        perror("InsomniaTestHome: stat");
        refuse("the temp directory cannot be used", tmp);
    }
    const char *problem = parent_problem(&parent);
    if (problem) refuse(problem, tmp);

    const char *sep = (len == 1) ? "" : "/";
    if (snprintf(g_root, sizeof g_root, "%s%sinsomnia-tests-process-%d-XXXXXX", tmp, sep, (int)getpid()) >= (int)sizeof g_root)
        refuse("the temp directory path is too long", tmp);
    if (mkdtemp(g_root) == NULL) {
        perror("InsomniaTestHome: mkdtemp");
        refuse("cannot make a directory in", tmp);
    }

    // The new directory is this user's, private, and sits in the parent
    // checked above. On any mismatch remove it if it is still an empty
    // directory (rmdir removes nothing else) and stop.
    struct stat made, up;
    char above[1100];
    snprintf(above, sizeof above, "%s/..", g_root);
    if (lstat(g_root, &made) != 0 || !S_ISDIR(made.st_mode) || made.st_uid != getuid()
        || (made.st_mode & 07777) != 0700 || stat(above, &up) != 0
        || up.st_dev != parent.st_dev || up.st_ino != parent.st_ino) {
        rmdir(g_root);
        refuse("the new directory is not the private one made in the temp directory", g_root);
    }
    if (setenv(kKey, g_root, 1) != 0) {
        perror("InsomniaTestHome: setenv");
        rmdir(g_root);
        refuse("cannot set INSOMNIA_HOME to", g_root);
    }
    memcpy(g_tmp, tmp, len + 1);
    g_dev = made.st_dev;
    g_ino = made.st_ino;
    g_have_root = 1;
    g_owner = getpid();
    atexit(remove_root);
}
