//
//  shim.c
//  CTingraLaunchd
//
//  Created by Larry Aasen on 2026-07-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

#include "include/CTingraLaunchd.h"

#include <launch.h>

// Forwards to launchd's `launch_activate_socket`. Keeping the <launch.h>
// include confined to this file means Swift sees only the one wrapper symbol,
// never the deprecated remainder of the launch API.
int tingra_launchd_activate_socket(const char *name, int **fds, size_t *count) {
    return launch_activate_socket(name, fds, count);
}
