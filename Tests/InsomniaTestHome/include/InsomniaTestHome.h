#ifndef INSOMNIA_TEST_HOME_H
#define INSOMNIA_TEST_HOME_H

/// Name of the environment variable the loader sets ("INSOMNIA_HOME").
const char *insomnia_test_home_key(void);

/// The throwaway directory INSOMNIA_HOME was pointed at when the test bundle
/// loaded, or NULL if the loader has not run.
const char *insomnia_test_home_root(void);

#endif
