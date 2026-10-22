# The VM kit and run mode

Another app can run the Omarchy VM without Try Omarchy's launcher window. Omarchy Installer does this for its Try mode ([one app plan](one-app.md)). It embeds three things from this repository's releases:

- **the kit:** `Try Omarchy Kit.app`, the full app without its bridged-networking daemon;
- **the run mode:** `omarchy-vm-helper --run-vm`, the kit's helper with no window;
- **the client:** `TryOmarchyKitClient`, a Swift library that starts the run mode and follows it.

## One session

The full app and the run mode run the VM through the same session (`VMRunSession`). The session downloads the image a new VM needs, starts the launch script, waits for QMP, pauses the VM across Mac sleep, stops it when its storage volume goes away, and reports the exit. The full app keeps its start menu, settings, VM moves and deletions, and the settings bridge. The run mode keeps nothing else: it has fixed defaults and no settings.

## The kit

`make kit` builds a production app, ad-hoc signed, and derives the kit from it (`macos/build-kit.sh`) in `dist/kit.noindex/`. `make package` and `make release` build the kit from the signed release app. `make publish` uploads `TryOmarchyKit.zip` and `TryOmarchyKit.zip.sha256` with the DMG and the image parts.

The kit carries the helper, the QEMU runtime, the firmware, the launch scripts, the `try-omarchy` package and the image's download manifest. It does not carry the image: its first start downloads the parts from the release the kit came from. Releases are never deleted, because installers pinned to an old kit need its parts.

The embedding app signs the kit's binaries as itself. macOS then asks for Accessibility, Microphone and Camera in that app's name.

## The kit's version

Every kit carries a manifest, `Contents/Resources/kit.json`, and each release also publishes it as `TryOmarchyKit.json`, so an app can read it before downloading the kit. `TryOmarchyKit.manifest()` in the client reads and validates it.

```json
{
  "format": 1,
  "version": "v1.2.3",
  "runProtocolVersion": 1,
  "buildDate": "2026-10-23T09:30:05Z"
}
```

- `version` is the release tag the kit was built from. A kit built from anything else, such as `make kit` on an untagged or modified commit, says `development`.
- `runProtocolVersion` is the run-mode protocol its helper speaks. A client runs only a kit with its own protocol version (`isSupported`).
- `buildDate` is when the kit was built, in UTC.
- Readers ignore keys they do not know. `format` changes only when a known key changes meaning.

Releases compare by their numbers (`TryOmarchyKitVersion`). A development kit compares newer than every release, so an app built with one keeps it rather than replacing it with a fetched kit. An app never runs a kit older than the one it embeds. A kit without a manifest predates it, so it is older than any kit that has one.

`make release` checks that the kit's manifest names the release's tag.

## The run mode

The app starts `omarchy-vm-helper --run-vm` from the kit, writes one configuration line to its standard input, and reads one event per line from its standard output. Diagnostics go to standard error. The protocol and its validation are in `macos/Sources/TryOmarchyKitClient/VMRunProtocol.swift`.

The configuration names the product, its icon (an `.icns` or `.png` file; the kit's own icon when absent), the storage folder (the full app's default folder when absent), the optional bridges, and memory and CPUs (automatic when absent). Audio and guest status always run. The settings bridge is never part of the run mode, so the guest gets no settings port and Omarchy's Setup menu shows no settings row.

The Omarchy window, its Dock entry and its application menu carry the product's name and icon. The Dock names a process after the file it starts from, so the launcher starts QEMU through a link named after the product, in the run's private folder. The signed binary stays in place. A name with a `/` cannot name a file, so its Dock entry keeps the binary's name.

The run mode writes `progress` (a phase and a percent), `ready`, `stopping`, `error` (a stable code and a message) and, last, `exited`. Error codes do not change between versions; messages may.

The run mode shuts down when it reads the `shutdown` command, when its input closes, or on a first signal. It asks Omarchy to shut down over QMP, waits up to a minute, then stops QEMU. So an app that crashes or is force-quit still shuts Omarchy down. A second signal stops QEMU at once.

The image download pauses on cellular and Low Data Mode connections and keeps the Mac awake.

## Sharing a VM

The full app and an embedding app open the same VM in the default folder, never at once: the VM folder's lock refuses the second, and the run mode reports `vm-already-open`. Either can boot a VM the other made. The `try-omarchy` package only upgrades, so an older kit never downgrades the guest. A launcher refuses a VM whose `vm.json` names a storage layout it does not know (`storage-layout-unknown`).
