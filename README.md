# SSD Protect

A macOS menu bar utility in development for people who keep an external drive
attached. Its goal is to let you protect selected drives from accidental software
ejects and eject them deliberately when you're ready to disconnect.

## Run the engineering spike

The app runs on macOS 14 or later. To build it, select Xcode 26 or later and run:

```sh
swift test
./scripts/build-app
open ".build/SSD Protect.app"
```

The build script signs the app locally with an ad-hoc signature. Set
`SIGNING_IDENTITY` to use an installed signing identity.

Use a disposable disk image for testing. The app recognizes HFS+, FAT and
exFAT volumes mounted directly on whole, leaf media under `/Volumes`. It
accepts verified disk images and explicitly external USB or Thunderbolt media
in that layout.

Use the protection switch on a directly connected external APFS drive to block
ordinary unmount and eject requests for its physical disk and volumes. The app
verifies the backing store and the current I/O Registry attachments before
arming the rule. By default, protection lasts for this attachment and app session.
If the app loses track of the drive's configuration, the menu shows protection
as suspended until it can verify the attachment again.

Open **Settings → General** to configure SSD Protect:

- **Launch at Login** opens the app when you sign in. If macOS requests approval,
  choose **Open Login Items…** to finish setup.
- **Restore protection on launch** remembers the drives you explicitly protect
  and checks them when the app opens or they reconnect. Restoration requires
  a unique hardware identifier, a matching media UUID and a verified non-startup
  layout. Drives that cannot be identified reliably stay session-only.
  Turning off a drive’s protection forgets its rule. Turning off restoration
  clears all saved rules and keeps current protection active until disconnect or quit.

- **Hide Finder Eject on encrypted APFS** updates the mount in place when you
  switch protection on or off for a verified external drive with one mounted
  encrypted APFS volume. Install the app in Applications, enable the setting,
  and approve SSD Protect under System Settings → General → Login Items &
  Extensions. SSD Protect remembers this setting across app updates. If a
  replacement build needs registration or approval, SSD Protect prompts at launch.
  Choose **Continue** to recover it, or **Later** to handle it from the menu.
  After a mount flag change, choose **Relaunch Finder…** to refresh Locations
  and Computer.
  Open files on the drive stay accessible. Turning off the setting offers to clear the flag on the listed
  mounted volumes before unregistering the helper. Relaunch Finder afterward. If the helper is unavailable, the protection switch still controls
  ordinary eject protection. Choose **Retry Finder Update** on the drive to try again.
  Opening the menu refreshes the inventory. The circular-arrow button refreshes it manually.

The **App icon** picker offers System, Light Cradle and Dark Cradle for the
running app and About. Finder uses the installed bundle’s system icon.

The menu omits the startup disk and groups simulator disk images under a
collapsed disclosure. It lists other mounted disk images and network shares
with their eligibility. Drive capacity is counted once per physical device.
Multi-store APFS containers and unverified devices are informational.

Click the eject symbol to disconnect a supported drive while keeping its protection
switch on. For APFS, the confirmation lists every mounted volume on the drive.
Cancel is the default. Choosing **Eject** starts a normal unmount and eject.
If a volume is busy, close the files using it and try again. To force eject
without confirmation, hold **Option** while clicking the eject symbol or
pressing Space on the focused button. This can discard unsaved changes on
any volume on the selected drive. Wait for the app to confirm eject before
disconnecting it.

Disk Arbitration does not identify the requester, so a concurrent request for
the same drive and phase can share that approval. Choosing **Quit** and confirming ends
enforcement.

To run the integration test, set `SSD_PROTECT_TEST_IMAGE` to the exact mount
path of a disposable, eligible image and run `swift test`. The test attempts
an ordinary unmount, checks that it was blocked, then ejects that image.
Use a second whole-media image with `SSD_PROTECT_TEST_FORCE_IMAGE` to test
force eject while the volume is busy.

For the APFS integration test, set `SSD_PROTECT_TEST_APFS_IMAGE` to the exact
mount path of one of two mounted sibling volumes on a disposable GPT/APFS
image. Use a separate disposable two-volume image with
`SSD_PROTECT_TEST_FORCE_APFS_IMAGE` to exercise force eject with a busy volume.
Both tests verify the backing image before exercising Disk Arbitration.

Set `SSD_PROTECT_TEST_RESTORE_IMAGE` to a separate disposable whole-media HFS+
image to exercise restoration across arbitrator restarts using fixture identity
and isolated preferences. This test leaves the image mounted.

See [Contributing](CONTRIBUTING.md) for the pull request workflow. Source is
available under the [MIT License](LICENSE).
