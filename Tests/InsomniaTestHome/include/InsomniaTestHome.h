#ifndef INSOMNIA_TEST_HOME_H
#define INSOMNIA_TEST_HOME_H

/// Name of the environment variable the loader sets ("INSOMNIA_HOME").
const char *insomnia_test_home_key(void);

/// The throwaway directory INSOMNIA_HOME was pointed at when the test bundle
/// loaded, or NULL if the loader has not run.
const char *insomnia_test_home_root(void);

/// The folder the loader made that directory in: TMPDIR when it is an
/// absolute path, else Darwin's per-user temp dir, else /tmp, with no
/// trailing slash. NULL if the loader has not run. Test helpers make their
/// scratch folders here (TestScratch).
const char *insomnia_test_scratch_base(void);

#endif
