# Next

- Bounded the plug-in pane's restart loop: a scene that will not start is reported on the bus, retried four times, then shown as "Plug-in Could Not Start" with Try Again.
- Added Input Settings… to the layer row's context menu.
- Added CHANGELOG.md to this project.
- app: You can now add an application's sound to the mixer, and it moves off your speakers into the program.
- app: Settings > Permissions now lists System Audio Recording, which the first application capture asks for.
- sdk: Added the application input kind, for an application's sound captured as an audio input.

- engine: Added TingraApplicationAudio, a standalone library capturing an application's sound by process tap.
- engine: Added the optional applications key to the project document.
- repo: Added code coverage to the CI unit test jobs, reported per package and app to Codecov.
