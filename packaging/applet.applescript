-- fb2-to-epub installer applet (UI conductor).
--
-- Thin AppleScript front-end: it shows dialogs and delegates ALL real work to the
-- bundled packaging/installer.sh (copied into Contents/Resources by build-app.sh).
-- Flow:
--   1. Verify Calibre is present (offer to open the download page if not).
--   2. choose folder, defaulting to ~/Desktop/fb2-to-epub (created if missing).
--   3. Run the bundled installer.sh with the chosen folder.
--   4. Show a success screen with where-to-drop-files guidance.
--   5. Surface any failure with the installer's own message.

on calibre_present()
	return (do shell script "test -x /Applications/calibre.app/Contents/MacOS/ebook-convert && echo yes || echo no") is "yes"
end calibre_present

on resource_path(theName)
	-- Resources sit next to this compiled script inside the .app bundle.
	set rsrc to (path to resource theName) as text
	return POSIX path of rsrc
end resource_path

on run
	-- 1. Calibre check ---------------------------------------------------------
	if not calibre_present() then
		set theChoice to button returned of (display dialog ¬
			"fb2-to-epub needs Calibre to convert books, but it isn't installed." & return & return & ¬
			"Install Calibre (free), then run this app again." ¬
			buttons {"Quit", "Get Calibre"} default button "Get Calibre" with title "fb2-to-epub" with icon caution)
		if theChoice is "Get Calibre" then
			open location "https://calibre-ebook.com/download_osx"
		end if
		return
	end if

	-- 2. Default folder + folder picker ---------------------------------------
	set defaultDir to (POSIX path of (path to home folder)) & "Desktop/fb2-to-epub"
	do shell script "mkdir -p " & quoted form of defaultDir

	display dialog ¬
		"fb2-to-epub watches a folder and turns any .fb2 / .fb2.zip you drop in it into .epub automatically." & return & return & ¬
		"Pick the folder to watch. The default is a 'fb2-to-epub' folder on your Desktop." ¬
		buttons {"Cancel", "Choose Folder…"} default button "Choose Folder…" with title "fb2-to-epub"

	set watchFolder to (choose folder with prompt "Choose the folder fb2-to-epub should watch:" ¬
		default location (defaultDir as POSIX file))
	set watchPath to POSIX path of watchFolder

	-- 3. Run the bundled installer --------------------------------------------
	try
		set installerPath to my resource_path("installer.sh")
	on error
		display dialog "fb2-to-epub: the installer is missing from the app bundle. Re-download the app." ¬
			buttons {"OK"} default button "OK" with title "fb2-to-epub" with icon stop
		return
	end try

	try
		set installOutput to do shell script ¬
			"/bin/bash " & quoted form of installerPath & " " & quoted form of watchPath
	on error errMsg number errNum
		display dialog ¬
			"fb2-to-epub couldn't finish installing." & return & return & errMsg ¬
			buttons {"OK"} default button "OK" with title "fb2-to-epub" with icon stop
		return
	end try

	-- 4. Success ---------------------------------------------------------------
	set fdaNote to ""
	set homePosix to POSIX path of (path to home folder)
	if watchPath starts with (homePosix & "Desktop/") ¬
		or watchPath starts with (homePosix & "Documents/") ¬
		or watchPath starts with (homePosix & "Downloads/") then
		set fdaNote to return & return & ¬
			"Note: your folder is in a protected location. If files don't convert, " & ¬
			"open System Settings → Privacy & Security → Full Disk Access, click +, then " & ¬
			"add this file (press ⇧⌘G and paste the path):" & return & ¬
			"~/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-runner.sh"
	end if

	display dialog ¬
		"fb2-to-epub is set up." & return & return & ¬
		"Watching:" & return & watchPath & return & return & ¬
		"Drop .fb2 or .fb2.zip files (or folders of them) into that folder — an .epub " & ¬
		"appears next to each one automatically." & fdaNote ¬
		buttons {"Open Folder", "Done"} default button "Done" with title "fb2-to-epub"

	if button returned of result is "Open Folder" then
		do shell script "open " & quoted form of watchPath
	end if
end run
