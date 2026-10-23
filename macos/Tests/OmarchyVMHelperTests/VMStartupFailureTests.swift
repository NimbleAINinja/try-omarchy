import Testing
@testable import OmarchyVMHelper

@Suite("VM startup failure recovery")
struct VMStartupFailureTests {
    @Test("A failed integrity check explains replacement without erasing the VM")
    func damagedApp() {
        let message = VMStartupFailure.message(
            status: 1,
            standardError: "run-qemu-gpu: the installed app is damaged or has an invalid code signature\n"
        )
        #expect(message.contains("code-signature check"))
        #expect(message.contains("Replacing the app keeps your saved VM"))
    }

    @Test("The actual launcher failure takes precedence over an optional probe crash")
    func launcherExplanation() {
        let message = VMStartupFailure.message(
            status: 1,
            standardError: "Abort trap: 6 during virtualization probe\n[qemu-gpu] using the compatible EL1 path\nrun-qemu-gpu: QEMU exited before creating its private QMP socket\n"
        )
        #expect(message.contains("QEMU exited before creating its private QMP socket"))
        #expect(!message.contains("Abort trap"))
        #expect(!message.contains("Reinstall"))
    }

    @Test("Unknown failures preserve bounded diagnostics and allow a retry")
    func unknownFailure() {
        let message = VMStartupFailure.message(status: 134, standardError: "Error: HV_NO_RESOURCES\n")
        #expect(message.contains("exit status 134"))
        #expect(message.contains("Try launching again"))
        #expect(message.contains("HV_NO_RESOURCES"))
        #expect(!message.contains("Reinstall"))
        #expect(VMStartupFailure.message(status: 1, standardError: "").contains("exit status 1"))
        #expect(VMStartupFailure.message(status: 1, standardError: String(repeating: "x", count: 5_000)).count < 2_000)
        #expect(!VMStartupFailure.message(status: 1, standardError: "error\u{0}").contains("\u{0}"))
    }

    @Test("A VM another app holds names the other app instead of an exit status")
    func vmAlreadyOpen() {
        let message = VMStartupFailure.message(
            status: 1,
            standardError: "[qemu-gpu] checking the VM folder\nrun-qemu-gpu: this VM is already open\n"
        )
        #expect(message == "Omarchy is already open in another app, such as Omarchy Installer. Shut it down there, then start it again here.")
        #expect(!message.contains("exit status"))
        #expect(VMStartupFailure.message(status: 1, standardError: "run-qemu-gpu: this VM is already open elsewhere\n")
            .contains("exit status 1"))
    }
}
