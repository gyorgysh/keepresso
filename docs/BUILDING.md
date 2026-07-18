# Building Keepresso yourself

Keepresso is open source, so you can build and run your own copy on your Mac. You
do **not** need an Apple Developer account: building and running locally signs the
app with your own machine's developer identity, which is all you need to run it.

## What you need

- macOS 14 (Sonoma) or later
- **Xcode 26 or later**, including the macOS 26 SDK (the full Xcode app from the
  App Store, not just the Command Line Tools). Keepresso still deploys to
  macOS 14; newer APIs are runtime availability-gated in the built app.
- **XcodeGen**, which turns [`project.yml`](../project.yml) into an Xcode project:

  ```sh
  brew install xcodegen
  ```

  (Other install options are at [github.com/yonaskolb/XcodeGen](https://github.com/yonaskolb/XcodeGen).)

## Build and run

```sh
git clone https://github.com/gyorgysh/keepresso.git
cd keepresso

xcodegen generate          # creates Keepresso.xcodeproj from project.yml
open Keepresso.xcodeproj    # then press Cmd-R to build and run
```

The cup appears in your menu bar. Keepresso is a menu-bar agent, so it has no Dock
icon: look up top, not in the Dock.

There's also a one-step helper that does the generate-and-open for you:

```sh
./scripts/run.sh
```

## Build from the command line

If you'd rather not open Xcode:

```sh
xcodebuild build \
  -project Keepresso.xcodeproj \
  -scheme Keepresso \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

The built app lands in Xcode's DerivedData. Running it from Xcode (Cmd-R) is the
easiest way to launch your own build.

## Run the tests

The behavior lives in the `KeepressoCore` library and is fully unit tested,
independent of any UI:

```sh
swift build      # build the core library
swift test       # run the test suite
```

## Good to know

- The generated `Keepresso.xcodeproj` is not checked in. Re-run `xcodegen generate`
  after pulling changes or editing `project.yml`.
- **Closed-display mode** changes a system setting (`pmset disablesleep`), so it
  asks for your administrator password when you turn it on.
- A build you make yourself is for your own use. Most people just download the
  notarized release build instead.
