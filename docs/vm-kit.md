# The VM kit and run mode

Another app can run the Omarchy VM without Try Omarchy's launcher window. Omarchy Installer does this for its Try mode ([one app plan](one-app.md)). It embeds three things from this repository's releases:

- **the kit:** `Try Omarchy Kit.app`, the full app without its bridged-networking daemon;
- **the run mode:** `omarchy-vm-helper --run-vm`, the kit's helper with no window;
- **the client:** `TryOmarchyKitClient`, a Swift library that starts the run mode and follows it.

## One session

The full app and the run mode run the VM through the same session (`VMRunSession`). The session downloads the image a new VM needs, starts the launch script, waits for QMP, pauses the VM across Mac sleep, stops it when its storage volume goes away, and reports the exit. Both read the same stored settings and serve the settings bridge. The full app keeps its start menu, VM moves and deletions.

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

Releases compare by their numbers (`TryOmarchyKitVersion`). A development kit compares newer than every release, so an app built with one keeps it rather than replacing it with a fetched kit. For that reason an installer refuses a fetched kit whose version is `development`, and an installer's release build refuses to embed one; `TryOmarchyKitVersion.isDevelopment` checks it. An app never runs a kit older than the one it embeds. A kit without a manifest predates it, so it is older than any kit that has one.

`make release` checks that the kit's manifest names the release's tag.

## The run mode

The app starts `omarchy-vm-helper --run-vm` from the kit, writes one configuration line to its standard input, and reads one event per line from its standard output. Diagnostics go to standard error. The protocol and its validation are in `macos/Sources/TryOmarchyKitClient/VMRunProtocol.swift`.

The configuration names the product, its icon (an `.icns` or `.png` file; the kit's own icon when absent) and the optional bridges. Its storage folder, memory, CPUs and network are fallbacks for a VM with no stored settings ([settings](#settings)). Audio, guest status and the settings bridge always run.

The Omarchy window, its Dock entry and its application menu carry the product's name and icon. The Dock names a process that has no app bundle after its file, even when it starts through a link. So the launcher starts QEMU from a minimal app bundle named after the product, in the run's private folder, whose executable links to the signed binary. The binary stays in place, so its signature and the bridges' check of the QEMU process are unchanged. A name that cannot be a file name, with a `/` or longer than 251 bytes, keeps the binary's name in the Dock.

The run mode writes `progress` (a phase and a percent), `ready`, `stopping`, `error` (a stable code and a message) and, last, `exited`. Error codes do not change between versions; messages may.

The run mode shuts down when it reads the `shutdown` command, when its input closes, or on a first signal. It asks Omarchy to shut down over QMP, waits up to a minute, then stops QEMU. So an app that crashes or is force-quit still shuts Omarchy down. A second signal stops QEMU at once.

The image download pauses on cellular and Low Data Mode connections and keeps the Mac awake.

## Settings

The run mode starts the VM with the settings the launcher window stored, and uses the configuration only for what was never stored:

- **the VM folder:** the folder chosen in the launcher, then the configuration's `storageRoot`, then the default folder. A chosen folder that is missing, or a choice that cannot be read, stops the run with `storage-unavailable`; it never falls back to another VM.
- **memory and CPUs** (and the disk's maximum size): the stored resources, then the configuration's `memoryMiB` and `cpus`, then the launcher's automatic choice.
- **networking:** the stored mode, then the configuration's `network`. A configuration that asks for bridged networking in a kit without the networking daemon fails with `bridged-network-unavailable`, as before; a stored bridged choice starts with shared networking instead, so Try is never stuck.
- **port forwarding, the shared folder, the USB device, Immersive Mode and the camera notch:** stored only. A port that is in use fails with `launch-failed`.

Audio follows the Mac's default devices. The development overrides (`OMARCHY_QEMU_GPU_STATE_ROOT`, `OMARCHY_QEMU_GPU_PORT_FORWARDS` and the like) still win, and `VMRunClient` never passes them on.

Choosing Omarchy's settings row in its Setup menu opens the launcher's window from the run mode's process, named after the product. Like the full app's settings while Omarchy runs, it is an accessory window: it comes to the front with the keyboard, and the process never appears in the Dock or the menu bar. The process takes the configuration's icon, and its About panel names the product, so no system UI shows the kit. The window has the full app's sharing, network, virtual machine and Immersive Mode settings, and the permission rows, which ask macOS in the embedding app's name. It has no launch, restart, shut down, Skip Launcher or update check: the embedding app owns those. Changes apply at the next start. Quitting from the window shuts Omarchy down, like the `shutdown` command.

Settings are stored in files, not in an app's preferences, so any kit reads the same ones whichever app it runs under:

- `settings.json` in the VM's folder, beside `launcher-settings.json`, holds the VM's settings. It moves and is deleted with the VM.
- `storage-location.json` in `~/Library/Application Support/Try Omarchy` holds which folder is the VM.

Both are private (0600) from their first byte and versioned, and saves lock the folder, so the full app and the run mode never lose each other's changes. A file that is not private, is too large or comes from a newer schema is ignored and never overwritten; for `storage-location.json` that stops the launch instead of using the default folder. A file is a JSON object with `schemaVersion` and `settings`. A save keeps every key it does not know, at the top level and in `settings`, so keys a newer kit adds survive an older kit's save. A setting that was reset is stored as `null`.

Older versions of the full app kept these settings in its UserDefaults (`dev.tryomarchy.native`). Each value moves into the file the first time the file lacks it, whichever app writes the file first. The run mode reads those UserDefaults without changing them, and the full app removes each value once the file has it. A VM folder set by `OMARCHY_QEMU_GPU_STATE_ROOT` never takes them.

## Sharing a VM

The full app and an embedding app open the same VM in the default folder, never at once: the VM folder's lock refuses the second, and the run mode reports `vm-already-open`. Either can boot a VM the other made. The `try-omarchy` package only upgrades, so an older kit never downgrades the guest. A launcher refuses a VM whose `vm.json` names a storage layout it does not know (`storage-layout-unknown`).
