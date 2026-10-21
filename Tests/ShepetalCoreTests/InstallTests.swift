import XCTest
@testable import ShepetalCore

/// The update must never restart Shepetal under someone who is talking or in a meeting: a restart mid-dictation loses
/// the words, mid-meeting it cuts the recording.
final class UpdateGateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnyWorkBlocksBothScheduledAndManualInstalls() {
        for a in [Activity(dictating: true), Activity(meeting: true), Activity(retranscribing: true)] {
            XCTAssertFalse(UpdateGate.allows(a, now: now), "\(a)")
            XCTAssertFalse(UpdateGate.allows(a, now: now, manual: true), "a manual install must also wait: \(a)")
        }
    }

    // Someone who pressed fn 19 minutes ago is likely to press it again; at 20 minutes the update may go in.
    func testTwentyQuietMinutesAfterTheLastFnPress() {
        XCTAssertFalse(UpdateGate.allows(Activity(lastFnPress: now - (20 * 60 - 1)), now: now))
        XCTAssertTrue(UpdateGate.allows(Activity(lastFnPress: now - 20 * 60), now: now))
        XCTAssertTrue(UpdateGate.allows(Activity(), now: now), "no fn press since launch is idle")
    }

    func testManualInstallIgnoresTheQuietMinutes() {
        XCTAssertTrue(UpdateGate.allows(Activity(lastFnPress: now - 5), now: now, manual: true))
    }

    func testWaitingHintNamesTheWork() {
        XCTAssertEqual(UpdateGate.waiting(Activity(meeting: true, retranscribing: true)),
                       "Shepetal restarts to update when the meeting ends")
        XCTAssertNil(UpdateGate.waiting(Activity(lastFnPress: now)))
    }
}

final class OnboardingFlowTests: XCTestCase {
    func testStepsWithAndWithoutRequiredSignIn() {
        XCTAssertEqual(OnboardingFlow(signInNeeded: true).steps, [.permissions, .signIn, .tryIt])
        XCTAssertEqual(OnboardingFlow(signInNeeded: false).steps, [.permissions, .tryIt])
    }

    // Dictation cannot work without the three required permissions; System Audio is for meetings only and is not
    // even an input, so it can never hold the user on step 1.
    func testContinueNeedsTheRequiredPermissionsOnly() {
        var f = OnboardingFlow(signInNeeded: true)
        XCTAssertNil(f.next(requiredGranted: false, signedIn: true))
        XCTAssertEqual(f.step, .permissions)
        XCTAssertNotNil(f.next(requiredGranted: true, signedIn: false))
        XCTAssertEqual(f.step, .signIn)
        XCTAssertNil(f.next(requiredGranted: true, signedIn: false), "a sign-in build cannot dictate signed out")
        XCTAssertNotNil(f.next(requiredGranted: true, signedIn: true))
        XCTAssertEqual(f.step, .tryIt)
    }

    // Start at login is the .pkg's old default, applied on Done only: a window closed halfway changes nothing.
    func testStartAtLoginIsRegisteredOnlyOnDone() {
        var f = OnboardingFlow(signInNeeded: false)
        XCTAssertEqual(f.next(requiredGranted: true, signedIn: false)?.registerLoginItem, false)
        let done = f.next(requiredGranted: true, signedIn: false)
        XCTAssertEqual(done?.done, true)
        XCTAssertEqual(done?.registerLoginItem, true)

        var off = OnboardingFlow(signInNeeded: false)
        off.startAtLogin = false
        _ = off.next(requiredGranted: true, signedIn: false)
        XCTAssertEqual(off.next(requiredGranted: true, signedIn: false)?.registerLoginItem, false)
    }

    func testBackStopsAtTheFirstStep() {
        var f = OnboardingFlow(signInNeeded: false)
        f.back()
        XCTAssertEqual(f.step, .permissions)
        _ = f.next(requiredGranted: true, signedIn: false)
        f.back()
        XCTAssertEqual(f.step, .permissions)
    }

    func testOpensAtFirstLaunchAndWhenAPermissionIsMissing() {
        XCTAssertTrue(OnboardingFlow.opensAtLaunch(done: false, requiredMissing: false))
        XCTAssertTrue(OnboardingFlow.opensAtLaunch(done: true, requiredMissing: true))
        XCTAssertFalse(OnboardingFlow.opensAtLaunch(done: true, requiredMissing: false))
    }
}

/// Uninstall is the one button that can remove someone's work, so it hides from test builds and the DMG, waits for
/// work to end, keeps recordings unless asked, and moves the bundle only after what needs the bundle has run.
final class UninstallPlanTests: XCTestCase {
    let model = URL(fileURLWithPath: "/u/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3")
    let caches = URL(fileURLWithPath: "/u/Library/Caches/io.backant.shepetal")
    let data = URL(fileURLWithPath: "/u/Library/Application Support/Shepetal")
    let app = URL(fileURLWithPath: "/Applications/Shepetal.app")

    func plan(fn: Bool = true, deleteData: Bool) -> [UninstallStep] {
        UninstallPlan.steps(fnKeyRestorable: fn, deleteData: deleteData, model: model, caches: caches, data: data, apps: [app])
    }

    func testRecordingsStayUnlessTicked() {
        XCTAssertFalse(plan(deleteData: false).contains(.trash(data)))
        XCTAssertFalse(plan(deleteData: false).contains(.deleteSettings))
        XCTAssertTrue(plan(deleteData: true).contains(.trash(data)))
    }

    func testOrder() {
        let s = plan(deleteData: true)
        XCTAssertEqual(s.first, .unregisterLoginItem, "SMAppService needs the bundle still in place")
        XCTAssertLessThan(s.firstIndex(of: .restoreFnKey)!, s.firstIndex(of: .deleteSettings)!,
                          "the old 🌐 value is read from the settings")
        XCTAssertLessThan(s.firstIndex(of: .cancelPendingUpdate)!, s.firstIndex(of: .quit)!,
                          "a staged update would put the app back when it quits")
        XCTAssertEqual(s.suffix(2), [.trash(app), .quit])
        XCTAssertFalse(plan(fn: false, deleteData: false).contains(.restoreFnKey))
    }

    func testHiddenForOtherBuildsAndOnTheDMG() {
        XCTAssertTrue(UninstallPlan.offered(bundleID: "io.backant.shepetal", readOnlyVolume: false))
        XCTAssertFalse(UninstallPlan.offered(bundleID: "io.backant.shepetal.check", readOnlyVolume: false))
        XCTAssertFalse(UninstallPlan.offered(bundleID: "io.backant.shepetal", readOnlyVolume: true))
    }

    func testDisabledWhileBusy() {
        XCTAssertEqual(UninstallPlan.blocker(Activity(meeting: true)), "Finish the meeting recording first")
        XCTAssertNotNil(UninstallPlan.blocker(Activity(dictating: true)))
        XCTAssertNotNil(UninstallPlan.blocker(Activity(retranscribing: true)))
        XCTAssertNil(UninstallPlan.blocker(Activity(lastFnPress: Date())), "a recent fn press is not work under way")
    }
}

final class MovePromptTests: XCTestCase {
    func offers(_ path: String, readOnly: Bool = false, id: String = "io.backant.shepetal", asked: Bool = false) -> Bool {
        MovePrompt.offers(path: path, home: "/Users/p", readOnlyVolume: readOnly, bundleID: id, asked: asked)
    }

    func testOfferedWhereSparkleCannotUpdate() {
        XCTAssertTrue(offers("/Volumes/Shepetal/Shepetal.app", readOnly: true))
        XCTAssertTrue(offers("/Users/p/Downloads/Shepetal.app"))
        XCTAssertTrue(offers("/private/var/folders/x/AppTranslocation/1F2E/d/Shepetal.app"))
    }

    func testNeverInAnApplicationsFolderNorTwiceNorForTestBuilds() {
        XCTAssertFalse(offers("/Applications/Shepetal.app"))
        XCTAssertFalse(offers("/Users/p/Applications/Shepetal.app"))
        XCTAssertFalse(offers("/Users/p/Downloads/Shepetal.app", asked: true), "asked once")
        XCTAssertFalse(offers("/Users/p/Downloads/Shepetal.app", id: "io.backant.shepetal.check"))
    }

    // Moving an old DMG's copy over a newer installed one would be a downgrade the user did not ask for.
    func testANewerInstalledCopyIsOpenedNotReplaced() {
        XCTAssertEqual(MovePrompt.move(installedBuild: 600, runningBuild: 512), .openInstalled)
        XCTAssertEqual(MovePrompt.move(installedBuild: 512, runningBuild: 512), .replace)
        XCTAssertEqual(MovePrompt.move(installedBuild: 400, runningBuild: 512), .replace)
        XCTAssertEqual(MovePrompt.move(installedBuild: nil, runningBuild: 512), .copy)
    }
}
