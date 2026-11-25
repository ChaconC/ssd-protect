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

Use a disposable disk image for testing. The spike recognizes HFS+, FAT and
exFAT volumes mounted directly on whole, leaf media under `/Volumes`. It
accepts verified disk images and explicitly external USB or Thunderbolt media
in that layout.

The menu also shows the startup disk, partitioned drives, mounted disk images
and network shares with their eligibility reasons. APFS volumes appear under
their backing disk when all physical stores resolve to that disk. The displayed
capacity is the total device size. These inventory rows are informational.

Enable the switch beside your test volume, then request an ordinary unmount.
The volume should stay mounted. In the menu, **Eject…** asks for confirmation
before requesting a normal unmount and eject. Enrollment lasts for the current
attachment and app session. Disk Arbitration does not identify the requester,
so a simultaneous request for the same drive and phase can share the confirmed
operation’s approval. **Quit and Stop Protection** ends enforcement.

To run the integration test, set `SSD_PROTECT_TEST_IMAGE` to the exact mount
path of a disposable, eligible image and run `swift test`. The test attempts
an ordinary unmount, checks that it was blocked, then ejects that image.

See [Contributing](CONTRIBUTING.md) for the pull request workflow. Source is
available under the [MIT License](LICENSE).
