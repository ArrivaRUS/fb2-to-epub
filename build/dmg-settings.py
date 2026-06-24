# dmgbuild settings for fb2-to-epub.
#
# Why dmgbuild (not create-dmg): create-dmg drives Finder over Apple Events to lay
# out the window. In a headless build there is no Automation (TCC) grant, so the
# layout step silently no-ops — that produced the broken .dmg (920px window over a
# 660px background → white gap, generic positions). dmgbuild writes the .DS_Store
# directly with ds_store/mac_alias, no Finder, so it works headless.
#
# Driven by make-dmg.sh via defines (-D): app=<path>, bg=<1x png>, icon=<icns>,
# appname=<NAME>. Background HiDPI: point at the 1x png; dmgbuild auto-discovers the
# sibling <name>@2x.png and compiles a multi-rep TIFF (tiffutil -cathidpicheck) so
# the background is crisp on Retina.

import os.path

app = defines["app"]                 # absolute path to the staged .app
appname = defines["appname"]         # e.g. "fb2-to-epub"
background_1x = defines["bg"]        # absolute path to 960x440 png (1x)
volicon = defines.get("icon")        # absolute path to .icns for the volume

app_basename = os.path.basename(app)

# --- volume ----------------------------------------------------------------
# NOTE: the volume NAME is passed via the dmgbuild CLI (-V / build_dmg volume_name),
# not from this settings file — make-dmg.sh sets it (and uses a unique name when
# testing, to dodge Finder remembering an old window size for the same volume name).
format = "UDZO"                       # zlib-compressed, read-only
filesystem = "HFS+"

# Contents of the volume: the app + a symlink to /Applications.
files = [app]
symlinks = {"Applications": "/Applications"}

# Volume icon = the app icon (copied straight to .VolumeIcon.icns), so the mounted
# disk shows our book-flash too. Use `icon` (direct), NOT `badge_icon` (which would
# composite the icon onto a generic disk-image badge).
if volicon:
    icon = volicon

# --- window geometry (design-agreed) ---------------------------------------
# macOS 26 opens the DMG window ~920x436 (visible content ~920x408) regardless of the
# remembered size. We size the window to 920x440 and draw the background art LARGER
# (960x440, dark to every edge) so a slightly-off window can never reveal white — only
# dark filler. Content is centered on the visible width (x=460).
# window_rect = ((x, y), (w, h)). x,y are screen position of the window origin.
window_rect = ((200, 120), (920, 440))

# Background art (1x; @2x sibling auto-picked up for Retina). The image may be LARGER
# than the window — that is intentional (see above). dmgbuild writes it as a
# top-left-anchored background (backgroundType=2 + backgroundImageAlias): no scaling,
# no centering. scroll_position=(0,0) below pins the content origin to top-left, so a
# wider Finder window reveals the dark filler to the right/below, never white.
background = background_1x

default_view = "icon-view"
show_icon_preview = False

# Chrome off → no white sidebar/toolbar/status strips bleeding past the art.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# --- icon view --------------------------------------------------------------
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
# Pin content origin to top-left so an over-sized background anchors top-left and a
# wider-than-designed Finder window reveals the dark filler, never a white gap.
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 120

# Icon positions (design-agreed): app left, Applications drop target right.
# Centered on the visible 920 window (centers x=290 / x=630, 340px apart, midpoint 460),
# synced 1:1 with the SVG background slots.
icon_locations = {
    app_basename: (290, 190),
    "Applications": (630, 190),
}

# Hide the app's ".app" extension in the window (dmgbuild runs `SetFile -a E` on the
# item inside the mounted image; no Finder scripting needed). Key is PLURAL.
hide_extensions = [app_basename]
