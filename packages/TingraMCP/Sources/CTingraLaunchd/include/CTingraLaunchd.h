//
//  CTingraLaunchd.h
//  CTingraLaunchd
//
//  Created by Larry Aasen on 2026-07-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

#ifndef CTINGRA_LAUNCHD_H
#define CTINGRA_LAUNCHD_H

#include <stddef.h>

// A minimal C shim exposing launchd socket activation to Swift.
//
// `launch_activate_socket` lives in <launch.h>, which is not surfaced by
// Swift's Darwin overlay, so the daemon reaches it through this one wrapper
// rather than importing the whole (largely deprecated) launch.h surface into
// Swift. See MCP.md, "Lifecycle: launchd socket activation".
//
// Adopts the listening socket(s) launchd created for the named entry in the
// LaunchAgent plist's `Sockets` dictionary. On success writes a malloc'd
// array of `count` file descriptors into `fds` (the caller frees it) and
// returns 0; on failure returns a POSIX error code (ESRCH when the process was
// not launched by launchd, so the daemon falls back to manual mode).
int tingra_launchd_activate_socket(const char *name, int **fds, size_t *count);

#endif /* CTINGRA_LAUNCHD_H */
