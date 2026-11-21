# Next

- Bounded the plug-in pane's restart loop: a scene that will not start is reported on the bus, retried four times, then shown as "Plug-in Could Not Start" with Try Again.
- Added Input Settings… to the layer row's context menu.
- Added CHANGELOG.md to this project.
- app: You can now add an application's sound to the mixer, and it moves off your speakers into the program.
- app: Settings > Permissions now lists System Audio Recording, which the first application capture asks for.
- sdk: Added the application input kind, for an application's sound captured as an audio input.
- app: You can now show safe areas, crop guides, and a tally border on a monitor from its Overlays menu.
- sdk: Added the monitor overlay seam, so a plug-in can draw on any monitor for the operator alone.
- app: You can now flip, show blue only, zebra stripes, or alpha on any monitor, input tiles included.
- app: You can now set overlay colors and line widths, show VU meters, and turn overlays on over MCP.
- app: Muting a video file's channel strip no longer freezes its picture in the shot.

- engine: Added TingraApplicationAudio, a standalone library capturing an application's sound by process tap.
- engine: Added the optional applications key to the project document.
- repo: Added code coverage to the CI unit test jobs, reported per package and app to Codecov.
- repo: Documented the monitor overlays design, PLUGINS.md Decisions 52 to 57.
- engine: Added TingraMonitorPlugIns, the first-party monitor overlays, and the optional monitorOverlays key.
