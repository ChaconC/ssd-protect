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
arming the rule. Protection lasts for this attachment and app session.
If the app loses track of the drive's configuration, the menu shows protection
as suspended until it can verify the attachment again.

The menu omits the startup disk and groups simulator disk images under a
collapsed disclosure. It lists other mounted disk images and network shares
with their eligibility. Drive capacity is counted once per physical device.
Multi-store APFS containers and unverified devices are informational.

Choose **Eject…** to disconnect a supported drive while keeping its protection
switch on. For APFS, the confirmation lists every mounted volume on the drive.
Cancel is the default. Choosing **Eject** starts a normal unmount and eject.
If a volume is busy, close the files using it and try again. Wait for the app
to confirm the eject before disconnecting the drive.

Disk Arbitration does not identify the requester, so a concurrent request for
the same drive and phase can share that approval. **Quit and Stop Protection**
ends enforcement.

To run the integration test, set `SSD_PROTECT_TEST_IMAGE` to the exact mount
path of a disposable, eligible image and run `swift test`. The test attempts
an ordinary unmount, checks that it was blocked, then ejects that image.

For the APFS integration test, set `SSD_PROTECT_TEST_APFS_IMAGE` to the exact
mount path of one of two mounted sibling volumes on a disposable GPT/APFS
image. The test verifies the backing image before exercising Disk Arbitration.

See [Contributing](CONTRIBUTING.md) for the pull request workflow. Source is
available under the [MIT License](LICENSE).
