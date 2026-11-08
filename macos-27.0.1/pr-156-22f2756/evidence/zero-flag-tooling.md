# Zero-flag Control-click input limit

No required zero-flag Control-click trial was valid. Six attempts were preserved, all in Pills.

The two ordinary attempts and the alternate input attempt posted Control-down before the mouse events, with each mouse event's flags set to 0, then Control-up. Control was down immediately before posting mouse-down. Before mouse-up, the system key state had already become false. Insomnia received a left press with eventFlags=0, appHeldFlags=0 and controlKey=0, and each became a 600-second start. These are plain-click outcomes after the tooling lost Control, not evidence of an app Control-click regression. The session file and SleepDisabled 1 were recognized as a start before the confirmation log. Surviving sessions were ended and sleep restoration checked.

Three bypass routing diagnostics kept Control down through both mouse posts. Two delivered the mouse events to the previously frontmost app rather than the status item. A direct status-agent attempt delivered the zero-flag events to that agent but produced no mouse event in Insomnia. None opened a menu or started a session. The explicit modifier values were never replaced in the app observer.

The ordinary prior-run Control method delivered an app right-press with eventFlags=0 and appHeldFlags=262144. It passed but does not test the changed left-press path. Two valid zero-flag trials in each of Pills, Compact and Minimal therefore remain unverified.

The selected traces are in [zero-flag-diagnostics](zero-flag-diagnostics/). The [machine-readable audit](zero-flag-tooling.json) records posted, delivered and app event values for every attempt. Original records, the working results ledger and cropped start pictures are retained under rejected/zero-flag-tooling/.
