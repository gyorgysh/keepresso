# dmgbuild settings for the Pervigil disk image. scripts/package-dmg.sh passes
# the app bundle, the background TIFF and the volume icon in with -D.
#
# The icon centres here are the ones background.html draws its arrow between.
# Move one and move the other.

import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides it)
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
icon = defines["volume_icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

# Finder counts the title bar in the window height, and the background starts
# below it, so 32 more points than the 400 point artwork. On a release with a
# shorter title bar the extra strip shows plain paper under the art.
window_rect = ((200, 120), (660, 432))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_sidebar = False
show_pathbar = False
show_tab_view = False
show_icon_preview = False

icon_size = 128
text_size = 13
arrange_by = None
grid_spacing = 100
label_pos = "bottom"

# The dot files are hidden, except on a Mac with Finder set to show every file.
# Parked far below the window so even there they sit out of view rather than
# peeking in under the art.
icon_locations = {
    app_name: (180, 205),
    "Applications": (480, 205),
    ".background.tiff": (180, 1000),
    ".VolumeIcon.icns": (330, 1000),
    ".DS_Store": (480, 1000),
}
