# Installer trial plan

Status: proposed on 2026-10-22, reviewed the same day. Nothing here is built yet.

## Summary

[Omarchy Installer](https://github.com/omacom/omarchy-mac-installer) installs Omarchy natively on a Mac. It gains a **Try it in a window** button that runs Omarchy in a virtual machine, inside the installer, with no settings.

Try Omarchy stays a separate app: the full VM, with every setting. This page calls it the full app. It keeps its name for now (see [open questions](#open-questions)).

Both apps run the VM through one shared core, built in this repository. They share the VM itself, so a trial becomes the full app's VM when someone installs the full app.

| | Installer trial | Full app |
| --- | --- | --- |
| For | Trying Omarchy for a few minutes or a week | Using Omarchy in a VM for good |
| Settings | None | Everything the launcher has today |
| Permissions | Offered on the Try screen, all optional | Offered in the launcher, all optional |
| Networking | Shared (NAT) | Shared or bridged, port forwarding |
| Storage | Default folder | Any folder, external drives |
| Next step | Install natively, or get the full app | Install natively |

## The trial

1. The installer's welcome screen offers **Try it in a window** beside **Continue**. The screen for an unsupported Mac offers it too, because there it is the only option. The screen that refuses a Mac with Omarchy already installed does not.
2. The Try screen offers Accessibility, so Command works as Super, and the microphone and camera. All three are optional, and the trial starts without them. It also shows how much disk the trial needs and how much is free.
3. **Download and start** is enabled when the disk has room. It downloads the image once, unpacks it, and boots Omarchy in its own window. Omarchy's own first-boot setup then asks for an account, keyboard and time zone, as on any Omarchy install.
4. While Omarchy runs, the installer shows its state, **Shut Down** and **Install on this Mac**.

The image download is about 3 GB in three parts and resumes where it stopped. Unpacking writes a 20 GiB disk file of which about 9 GB is allocated, and the compressed download is removed once the VM has started. The Try screen asks for 15 GB free, as the full app's manual does. The download pauses on cellular and Low Data Mode connections and keeps the Mac awake, following the installer's rules for its own downloads.

The trial uses fixed defaults: automatic memory (8 GiB on a Mac with 16 GiB or more, 4 GiB otherwise) and CPUs, shared networking, the default storage folder, and no shared folder, USB device or port forwarding. All the Mac bridges stay on: clipboard, audio, keyboard, time zone, battery, camera and sleep. The settings bridge stays off, so Omarchy's Setup menu shows no **Try Omarchy Settings** row; the guest already hides it when the port is absent. **Touch ID for sudo** works, and its prompt names the installer.

The Omarchy window is QEMU's own window, as in the full app, with its own Dock icon. Its menus say Try Omarchy for now.

**Shut Down**, quitting the installer, and closing the Omarchy window all ask Omarchy to shut down over QMP, wait up to a minute, and then stop QEMU. The installer shows **Shutting down** until the VM has exited, and quits only then. If the installer is force-quit or crashes, the run mode stops the VM the same way.

**Install on this Mac** shuts the VM down and continues into the native install. The plan review counts the space the VM's folder actually uses against free space.

## One VM

The trial and the full app open the same VM, in the full app's default folder.

- Someone who likes the trial installs the full app and finds the same Omarchy, now with settings. The image downloads once.
- When the full app is installed, the installer's button becomes **Open in Try Omarchy** and opens the full app, whose launcher starts the VM. The installer never runs a VM the full app has set up, which may live on another drive or use a shared folder.
- The VM folder's lock stops both apps from running the VM at once. The run mode reports this as its own error, so the installer can say that Omarchy is open in the full app.
- Either app can boot a VM the other made. The `try-omarchy` package only upgrades ([integration updates](integration-updates.md)), so an older core never downgrades the guest. The launcher does not compare a VM's recorded factory with the one it bundles. A core refuses a storage layout version it does not know rather than migrating it.

## Permissions

macOS grants permissions to the app a person sees. The installer asks for its own Accessibility, Microphone and Camera grants, separate from the full app's. Someone who moves to the full app grants them again there.

For that the installer signs the kit's binaries as itself, as it signs its other helpers, with the camera and audio-input entitlements on the app and the helper and the hypervisor and audio-input entitlements on QEMU, and declares camera and microphone usage descriptions in its Info.plist. The full app's build does the same today.

## The shared core

This repository builds the core, and both apps embed the same one.

- **The kit:** everything the full app ships today except its launcher window: the helper binary, the QEMU runtime, the firmware, the launch scripts, the `try-omarchy` package and the image's download manifest. Compressed it is about the size of today's DMG, 13 MB. It is published with each release, with its digest. The kit's bridged-networking daemon is not part of the trial: the trial never registers it, and the run mode refuses bridged mode without it.
- **The run mode:** a headless mode of the helper that prepares the image, starts QEMU, starts the bridges and the sleep handling, and shuts down. It takes a small versioned configuration (product name, storage folder, which bridges to start, memory and CPUs) and writes versioned JSON lines: progress with a phase and a percentage, ready, exited, and errors with a stable code and a message. The codes cover at least: VM already open, volume not APFS, macOS too old, hypervisor unavailable, not enough space, download failed, image digest mismatch, QEMU exited.
- **The client:** a small Swift library both apps use to start the run mode, follow its events, and shut it down. It validates every line it reads.

The installer embeds the kit from a pinned release and updates the pin when it wants a newer VM. The full app embeds the kit from its own build, so the trial runs the core the full app uses every day. The client and the kit come from the same release.

The kit's image parts and manifest live on this repository's GitHub releases. Installers pinned to an old kit need those assets, so releases are never deleted.

## Work

In this repository:

1. Move VM supervision out of the full app's launcher into the helper's run mode, and have the full app use it. What moves: the factory download, the storage folder checks, cloning and growing the disk, starting QEMU and its bridges, QMP readiness, pausing and resuming for Mac sleep, handling a volume unmount, and reporting exit. What stays in the full app: the start menu and its settings, the settings bridge window, moving and deleting VMs, the Accessibility prompt and the release checker. The bridges already run as separate helper processes started by the launch script, and do not change.
2. Add the client library as a Swift package product.
3. Add `make kit`, and publish the kit and its digest with each release.

In the installer:

1. Embed the pinned kit, sign it as the installer, and add the entitlements and usage descriptions above.
2. Add the Try screens, with the space check and the optional permissions, and the button that opens the full app instead when it is installed.
3. Count the VM's disk in the plan review.

## Testing

- In this repository, `make test` gains contract tests for the client library against the run mode's events and error codes, and `make e2e` runs the full app through the run mode.
- The installer checks the embedded kit's digest and signature in its assembly test, and runs the launcher's inspect-only self-check against it.
- The trial itself is checked by hand on a Mac: first start with and without each permission, shut down from each of the three places, the lock error with the full app running, and a second start.

Neither repository's CI can boot the VM.

## Open questions

- Whether to rename the full app. Not now; *Omarchy VM* is the working choice if it happens.
- Whether a Touch ID enrollment made by one app works in the other. Both read keys from the same folder under Application Support, and Secure Enclave keys are bound to the Mac rather than the app, so this should work. It needs a test.
- Whether the installer should also offer the full app's download, or only link to it.
- Whether the plan review offers to delete the trial VM before a native install, since the install leaves 9 GB or more in Application Support that the person may not use again.
