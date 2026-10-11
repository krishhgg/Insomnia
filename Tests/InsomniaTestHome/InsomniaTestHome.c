// Test-only. Linked into the test bundle, so this constructor runs when the
// bundle loads, before XCTest discovers a single test and whatever filter
// the run uses. Log.append and SessionManager.live resolve INSOMNIA_HOME
// at call time and fall back to the real ~/Library when it is unset; with
// the variable set here, no test, filtered or not, can write there.
// The directory is made under TMPDIR when that is an absolute path, so a
// run that sets TMPDIR keeps every file of the process home under it;
// Darwin's per-user temp dir and then /tmp only when TMPDIR is unset,
// empty or relative. Test helpers make their scratch folders under the same
// base (insomnia_test_scratch_base, TestScratch in TestSupport.swift).
// The directory is removed when the process exits normally; a removal that
// fails is reported on standard error with the path, for whoever ran the
// tests to remove by hand.

#include "InsomniaTestHome.h"

#include <errno.h>
#include <removefile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *const kKey = "INSOMNIA_HOME";
static char g_base[1024];
static char g_root[1024];
static int g_have_root = 0;
static pid_t g_owner = 0;

const char *insomnia_test_home_key(void) { return kKey; }

const char *insomnia_test_home_root(void) { return g_have_root ? g_root : NULL; }

const char *insomnia_test_scratch_base(void) { return g_have_root ? g_base : NULL; }

static void remove_root(void) {
    // Not in a forked child; only the process that made the directory removes it.
    if (!g_have_root || getpid() != g_owner) return;
    if (removefile(g_root, NULL, REMOVEFILE_RECURSIVE) != 0) {
        int err = errno;
        fprintf(stderr, "InsomniaTestHome: could not remove %s: %s\n", g_root, strerror(err));
    }
}

__attribute__((constructor))
static void insomnia_test_home_install(void) {
    const char *env = getenv("TMPDIR");
    int written;
    if (env && env[0] == '/') {
        written = snprintf(g_base, sizeof g_base, "%s", env);
    } else {
        size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, g_base, sizeof g_base);
        written = (n == 0 || n > sizeof g_base) ? snprintf(g_base, sizeof g_base, "%s", "/tmp") : (int)(n - 1);
    }
    if (written < 0 || (size_t)written >= sizeof g_base) {
        fprintf(stderr, "InsomniaTestHome: the temporary directory's path is too long; refusing to run tests against the real ~/Library\n");
        abort();
    }
    size_t len = strlen(g_base);
    while (len > 1 && g_base[len - 1] == '/') g_base[--len] = '\0';

    written = snprintf(g_root, sizeof g_root, "%s/insomnia-tests-process-%d-XXXXXX", g_base, (int)getpid());
    if (written < 0 || (size_t)written >= sizeof g_root) {
        fprintf(stderr, "InsomniaTestHome: the test home's path is too long; refusing to run tests against the real ~/Library\n");
        abort();
    }
    if (mkdtemp(g_root) == NULL) {
        perror("InsomniaTestHome: mkdtemp");
        fprintf(stderr, "InsomniaTestHome: refusing to run tests against the real ~/Library\n");
        abort();
    }
    if (setenv(kKey, g_root, 1) != 0) {
        perror("InsomniaTestHome: setenv");
        abort();
    }
    g_have_root = 1;
    g_owner = getpid();
    if (atexit(remove_root) != 0) {
        fprintf(stderr, "InsomniaTestHome: could not register the removal of %s; remove it by hand after the run\n", g_root);
    }
}
