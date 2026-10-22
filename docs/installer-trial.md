# Installer trial plan

Status: proposed on 2026-10-22. Nothing here is built yet.

## Summary

[Omarchy Installer](https://github.com/omacom/omarchy-mac-installer) installs Omarchy natively on a Mac. It gains a **Try it in a window** button that runs Omarchy in a virtual machine, inside the installer, with no settings.

Try Omarchy stays a separate app: the full VM, with every setting. It gets a new name (see [open questions](#open-questions)); this page calls it the full app.

Both apps run the VM through one shared core, built in this repository. They share the VM itself, so a trial becomes the full app's VM when someone installs the full app.

| | Installer trial | Full app |
| --- | --- | --- |
| For | Trying Omarchy for a few minutes or a week | Using Omarchy in a VM for good |
| Settings | None | Everything the launcher has today |
| Permissions | Asked before the first start | Asked in the launcher |
| Networking | Shared (NAT) | Shared or bridged, port forwarding |
| Storage | Default folder | Any folder, external drives |
| Next step | Install natively, or get the full app | Install natively |

## The trial

1. The installer's welcome screen offers **Try it in a window** beside **Continue**. The screen for an unsupported Mac offers it too, because there it is the only option.
2. The Try screen asks for Accessibility, so Command works as Super, and for the microphone and camera.
3. **Download and start** downloads the image once, then boots Omarchy in its own window.
4. While Omarchy runs, the installer shows its state, **Shut Down** and **Install on this Mac**. Quitting the installer shuts the VM down cleanly.

The trial uses fixed defaults: automatic memory and CPUs, shared networking, the default storage folder, and no shared folder, USB device or port forwarding. All the Mac bridges stay on: clipboard, audio, keyboard, time zone, battery, camera and sleep.

**Install on this Mac** shuts the VM down and continues into the native install. The plan review counts the VM's disk against free space.

## One VM

The trial and the full app open the same VM, in the full app's default folder.

- Someone who likes the trial installs the full app and finds the same Omarchy, now with settings. The image downloads once.
- When the full app is installed, the installer's button becomes **Open in** the full app. The installer never runs a VM the full app has set up, which may live on another drive or use a shared folder.
- The VM folder's lock stops both apps from running the VM at once.
- Either app can boot a VM the other made. The `try-omarchy` package only upgrades ([integration updates](integration-updates.md)), so an older core never downgrades the guest.

## Permissions

macOS grants permissions to the app a person sees. The installer asks for its own Accessibility, Microphone and Camera grants, separate from the full app's.

## The shared core

This repository builds the core, and both apps embed the same one.

- **The kit:** the helper binary, the QEMU runtime, the firmware, the launch scripts, the `try-omarchy` package and the image's download manifest. It is signed and published with each release, with its digest.
- **The client:** a small Swift library both apps use to start the VM, follow its progress, and shut it down.

The installer pins the kit by digest, as it pins its install engine, and updates the pin when it wants a newer VM. The full app embeds the kit from the same build, so the trial runs the core the full app uses every day.

## Work

In this repository:

1. Move VM supervision out of the full app's launcher into a headless run mode of the helper. Today the launcher prepares the image, starts QEMU, and then starts the bridges and the sleep handling. The run mode does all of that, takes a small versioned configuration, and reports progress, readiness and exit as JSON lines. The full app switches to it.
2. Add the client library as a Swift package product.
3. Add `make kit`, and publish the kit and its digest with each release.
4. Rename the full app. Keep the bundle ID `dev.tryomarchy.native` and the `Try Omarchy` folder names, so people keep their grants, settings and VM.

In the installer:

1. Embed the pinned kit, and keep QEMU's hypervisor entitlement when signing.
2. Add the Try screens, and the button that opens the full app instead when it is installed.
3. Count the VM's disk in the plan review.

## Open questions

- The full app's new name. *Omarchy VM* is the working choice.
- Whether a Touch ID enrollment made by one app works in the other. Both read keys from the same folder, but the Secure Enclave keys need checking.
- Whether the installer should also offer the full app's download, or only link to it.
