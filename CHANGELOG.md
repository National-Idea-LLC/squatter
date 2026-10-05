# Changelog

All notable user-facing changes to Squatter. Written for the people who use it — plain language, no file names or internal jargon.

## [Unreleased]

### Added

### Changed
- With the menu bar count on, Squatter now shows just its icon when there are no ports to list, instead of a 0.

### Fixed

### Removed

## [0.4.1] - 2026-08-30

Settings' ignore list got the redesign it needed: a full-width box to type ports into, and everything you have ignored shown as chips instead of a row apiece.

### Changed
- Settings' ignore list is laid out again. The box you type ports into is now full width, with the example `3000, 5173` sitting inside it as a hint rather than beside it as text you could not edit, and "Separate ports with a comma, a space, or a new line." moved up next to the box it describes. Everything you have ignored now appears as small chips under **Ports** and **Processes**, so eight ignored ports take two lines instead of eight rows — and you can tell at a glance which are ports and which are process names. Click a chip to stop ignoring it.

## [0.4.0] - 2026-08-30

Squatter now updates itself — this is the last version you install by hand — and the footer buttons, About links and row addresses all got a polish.

### Added
- You can now sort the list by PID, alongside Port and Process name (Settings). PID order is roughly the order things started in, so the server you launched last sits at the bottom.
- Settings now credits the company behind Squatter, with a link to ni.sa.
- Squatter can now update itself. It asks once whether it may check for updates; when one is found, a dot appears on the Settings gear and Settings › About offers Install Update. You can turn automatic checks on or off in Settings.

### Changed
- The buttons in the footer animate now. The refresh arrow spins while it scans, instead of being swapped out for a spinner; the eye draws its slash on and off as you show or hide ignored ports; and the gear gives a small bounce when you open Settings.
- In Settings, the "Open source, MIT" and copyright rows are links you can click anywhere along, marked with a ↗, rather than a label with a button parked at the end. Check for Updates and Report a Bug keep their buttons — those do something for you rather than just going somewhere.
- The Refresh button in the footer is now just the icon. The count beside it — "7 of 17", or "17 listening" when nothing is filtered — is gone from view; hover the button and the tooltip still tells you, and the menu bar keeps showing the number.
- Check for Updates in Settings now checks from inside the app instead of opening the Releases page.

### Fixed
- The address on each row is readable again. It was drawn in the accent colour, which washed out against the translucent panel on macOS 26 — how readable it was depended on your wallpaper. It now uses the same colour as the process name above it and is underlined, so it stays legible in light and dark mode over anything.

## [0.3.0] - 2026-08-29

A new app icon drawn for the way macOS renders icons now, the Liquid Glass look on macOS 26, and each row spells out its address so you can click straight through to it.

### Added
- Every row now shows its address — `http://localhost:3000` — on its own line, so you can read it without hovering. Click it to open in your browser, same as the ↗ button.

### Changed
- Squatter has a new app icon. It is the same dark panel with one lit green port, redrawn so macOS renders it with real depth and lighting instead of as a flat picture, and it now has its own dark and tinted versions that follow whatever appearance you have set.
- On macOS 26 and later, Squatter now uses the system's Liquid Glass look. The window, the search field, the footer buttons, and the buttons on each row are translucent and pick up whatever is behind them, and the list fades softly under the search field and the footer as you scroll. On macOS 15 the app looks exactly as it did before.

### Fixed
- The tooltips on each row's buttons now appear quickly enough to actually read. They were on the system's two-second delay, but the ⋯, ↗ and ✕ buttons only exist while you're hovering the row — so the tip usually arrived after you'd moved on, or never showed at all.
- Settings is easier to read: the explanations under each group are darker and now say what they are about instead of starting mid-sentence.
- The refresh icon in the footer no longer blinks every couple of seconds. It only spins when you ask for a refresh — the list and the counts still update on their own in the background, as before.

## [0.2.0] - 2026-08-29

Squatter now understands Docker: container ports show the container's name and stop the container instead of Docker itself. Plus two ways to quiet the list down to the ports you actually care about.

### Added
- Ports published by a Docker container now show the container's name and image (e.g. `api-db-1` / `postgres:16`) instead of `com.docker.backend`. A new "Docker integration" setting lets you turn this off; Squatter only runs the `docker` command when Docker is installed.
- Ports published by Docker now offer Stop Container, which stops that container instead of killing Docker itself.
- A new setting hides ports above a number you choose — 10,000 by default — so the list shows your dev servers instead of macOS background services. Off by default, so nobody's list changes on its own.
- You can now type ports straight into the ignore list in Settings — separate them with commas, spaces, or new lines — instead of waiting for a port to appear in the list so you can right-click it.
- Settings has a Report a Bug button that opens a new issue with your Squatter and macOS versions already filled in.

### Changed
- Settings now lists the ignore list before the About section, so the things you actually adjust come before the version and links.

### Fixed
- The "Hide ports above" field in Settings now looks like a field you can type in, instead of plain text.

## [0.1.2] - 2026-08-29

Squatter now installs with Homebrew, and opens on a Mac that is offline the first time you launch it. The app itself is unchanged from 0.1.1.

### Added
- Squatter can now be installed and updated with Homebrew: `brew install --cask National-Idea-LLC/tap/squatter`. The command was in the README before but never worked.

### Fixed
- Squatter now launches on a Mac that is offline or on a restricted network the first time you open it. Previously macOS could only confirm the app was notarized by checking with Apple over the internet.

## [0.1.1] - 2026-08-28

Safer kills and a scanner that can't hang: Force Kill now confirms, and two freeze bugs are gone.

### Changed
- The row under your pointer is now highlighted, so it's obvious which port the buttons act on.
- The row buttons stay readable when the row is selected or hovered.
- Killing a process now asks first: the row asks "Kill this process?" with Kill and Cancel. Only one row asks at a time, and Escape backs out. This applies however you start it — the ✕ button, the menu, or the Delete key.

### Fixed
- Force Kill in the right-click menu now asks before it acts. Previously it killed the process the instant you clicked it, with no way to back out.
- Squatter no longer freezes on machines with a very large number of listening ports.
- If the system tool Squatter uses to read ports ever stops responding, the list now shows an error you can retry instead of spinning forever.

## [0.1.0] - 2026-08-28

First public release: a menu bar app that shows what's listening on every port and lets you open, copy, or kill it.


### Added
- Menu bar icon that opens a list of every port your Mac is listening on, with the process name, PID, and address.
- Open a port in your browser, or copy its URL, port, or PID from the row or the right-click menu.
- Kill a process from its row. If it ignores the request, a Force Kill button appears after 2 seconds.
- Filter the list by port, process name, or PID.
- The list refreshes every 2 seconds while it's open, and shows a clear message when nothing is listening or the scan fails.
- Settings (⌘,): launch Squatter at login, and choose how often the list refreshes (1, 2, or 5 seconds).
- Ignore ports or processes you don't care about from the right-click menu. Hidden rows are counted in the footer, where one click shows them again; manage the list in Settings.
- Sort the list by port or by process name (Settings).
- Every row now has a ⋯ button with the full set of actions, so you don't have to know to right-click.
- Keyboard control: arrow keys move the selection, Return opens it in the browser, Delete kills it, and ⌘C copies its URL.
- Optional count in the menu bar showing how many ports are listening (Settings). It updates every 10 seconds while the list is closed.
- About section in Settings with the version, a Check for Updates button that opens the GitHub releases page, and a link to the source.

### Changed
- The app is now called Squatter. (It was OpenPorts during development.)
- Fresh look for the port list: a status light on every row (green means it's yours to kill, gray means another user owns it, red means it didn't exit), rows grouped into Yours, Other users, and Ignored, and bigger, easier-to-scan port numbers.
