# Homebrew Cask for Pervigil.
#
# This lives here as the source of truth. To make `brew install --cask pervigil`
# work, publish it to a tap repo named `bubb4rd/homebrew-pervigil` (a GitHub
# repo with this file under `Casks/`), after which:
#
#   brew install --cask bubb4rd/pervigil/pervigil
#
# Per release: bump `version` and set `sha256` to the DMG's hash
#   (shasum -a 256 dist/Pervigil-<version>.dmg), then commit to the tap.
# The `livecheck` block lets `brew livecheck` notice new GitHub releases.
cask "pervigil" do
  version "1.30.0"
  sha256 "dca52220ee843892b450c9f1ae57f762281f2fbd8207df13809a1f936c098075"

  url "https://github.com/bubb4rd/pervigil/releases/download/v#{version}/Pervigil-#{version}.dmg"
  name "Pervigil"
  desc "Menu-bar keep-awake app with triggers, timed sessions, and closed-display mode"
  homepage "https://github.com/bubb4rd/pervigil"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true # Pervigil updates itself via Sparkle
  depends_on macos: :sonoma

  app "Pervigil.app"
  # The caffeinate-style CLI, embedded in the app bundle (Contents/Helpers).
  binary "#{appdir}/Pervigil.app/Contents/Helpers/pervigil"

  zap trash: [
    "~/Library/Application Support/Pervigil",
    "~/Library/Caches/io.github.bubb4rd.pervigil",
    "~/Library/Group Containers/*.io.github.bubb4rd.pervigil",
    "~/Library/Preferences/io.github.bubb4rd.pervigil.plist",
  ]
end
