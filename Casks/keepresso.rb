# Homebrew Cask for Keepresso.
#
# This lives here as the source of truth. To make `brew install --cask keepresso`
# work, publish it to a tap repo named `gyorgysh/homebrew-keepresso` (a GitHub
# repo with this file under `Casks/`), after which:
#
#   brew install --cask gyorgysh/keepresso/keepresso
#
# Per release: bump `version` and set `sha256` to the DMG's hash
#   (shasum -a 256 dist/Keepresso-<version>.dmg), then commit to the tap.
# The `livecheck` block lets `brew livecheck` notice new GitHub releases.
cask "keepresso" do
  version "1.6.0"
  sha256 "040eb633c85437fbcde5efb71e1d039430657f9f4145786d5af98b08b92af7c0"

  url "https://github.com/gyorgysh/keepresso/releases/download/v#{version}/Keepresso-#{version}.dmg"
  name "Keepresso"
  desc "Menu-bar keep-awake app with triggers, timed sessions, and closed-display mode"
  homepage "https://github.com/gyorgysh/keepresso"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true # Keepresso updates itself via Sparkle
  depends_on macos: :sonoma

  app "Keepresso.app"

  zap trash: [
    "~/Library/Caches/sh.gyorgy.keepresso",
    "~/Library/Preferences/sh.gyorgy.keepresso.plist",
  ]
end
