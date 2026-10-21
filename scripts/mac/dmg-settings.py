# dmgbuild settings for the drag-and-drop DMG (scripts/make-dmg.sh passes app, background and icon with -D).
# dmgbuild writes the Finder layout (.DS_Store) itself, so nothing scripts Finder (that fails on a CI runner).
app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821
background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {"Shepetal.app": (160, 200), "Applications": (480, 200)}
hide_extension = ["Shepetal.app"]
