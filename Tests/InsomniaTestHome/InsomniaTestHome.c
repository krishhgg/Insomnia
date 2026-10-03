// Test-only. Linked into the test bundle, so this constructor runs when the
// bundle loads, before XCTest discovers a single test and whatever filter
// the run uses. Log.append and SessionManager.live resolve INSOMNIA_HOME
// at call time and fall back to the real ~/Library when it is unset; with
// the variable set here, no test, filtered or not, can write there.
// The directory is removed when the process exits normally.

#include "InsomniaTestHome.h"

#include <removefile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *const kKey = "INSOMNIA_HOME";
static char g_root[1024];
static int g_have_root = 0;
static pid_t g_owner = 0;

const char *insomnia_test_home_key(void) { return kKey; }

const char *insomnia_test_home_root(void) { return g_have_root ? g_root : NULL; }

static void remove_root(void) {
    // Not in a forked child; only the process that made the directory removes it.
    if (!g_have_root || getpid() != g_owner) return;
    removefile(g_root, NULL, REMOVEFILE_RECURSIVE);
}

__attribute__((constructor))
static void insomnia_test_home_install(void) {
    char tmp[1024];
    size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, sizeof tmp);
    if (n == 0 || n > sizeof tmp) {
        const char *env = getenv("TMPDIR");
        snprintf(tmp, sizeof tmp, "%s", (env && *env) ? env : "/tmp/");
    }
    size_t len = strlen(tmp);
    if (len > 0 && tmp[len - 1] == '/') tmp[len - 1] = '\0';

    snprintf(g_root, sizeof g_root, "%s/insomnia-tests-process-%d-XXXXXX", tmp, (int)getpid());
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
    atexit(remove_root);
}
