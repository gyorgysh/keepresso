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
  version "1.2.0"
  sha256 "ca7dc2158d640588fce5a13ab79b09cea31a2563154ce6dc42b44990578840fd"

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
