#ifndef INSOMNIA_TEST_HOME_H
#define INSOMNIA_TEST_HOME_H

/// Name of the environment variable the loader sets ("INSOMNIA_HOME").
const char *insomnia_test_home_key(void);

/// The throwaway directory INSOMNIA_HOME was pointed at when the test bundle
/// loaded, or NULL if the loader has not run.
const char *insomnia_test_home_root(void);

/// The directory the loader made that one in, without a trailing slash:
/// TMPDIR when the run set it, else Darwin's per-user temp directory, then
/// /tmp. NULL if the loader has not run.
const char *insomnia_test_home_temp_dir(void);

#endif
