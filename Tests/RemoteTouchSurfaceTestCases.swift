//
//  RemoteTouchSurfaceTestCases.swift
//  HyperVibe
//
//  Standalone tests for RemoteTouchSurface.isEligibleRemoteSurface (mc-25ko).
//
//  No test target exists in this repo (Package.swift deliberately excludes
//  MultitouchSupport.framework — see its header comment — so `swift test` cannot build the
//  app target, and the documented build path is build.sh's direct swiftc invocation, not
//  SwiftPM). RemoteTouchSurface.swift has zero framework dependencies for exactly this reason,
//  so it can be compiled and run standalone with plain swiftc, mirroring build.sh's own style.
//  Run via: Tests/run-tests.sh
//

// mc-25ko: Magic Trackpad swipes were being treated as Siri Remote gestures because
// TouchHandler's old heuristic picked whatever non-built-in MT device had the smallest
// surface, with no absolute check against what the remote's surface actually looks like.
// These pin the fixed discrimination function's behavior against the concrete devices
// involved in that bug report.

func runRemoteTouchSurfaceTests() -> Int {
    var failures = 0

    func expectTrue(_ value: Bool, _ label: String) {
        if value {
            print("  ok   - \(label)")
        } else {
            print("  FAIL - \(label) (expected true, got false)")
            failures += 1
        }
    }

    func expectFalse(_ value: Bool, _ label: String) {
        if !value {
            print("  ok   - \(label)")
        } else {
            print("  FAIL - \(label) (expected false, got true)")
            failures += 1
        }
    }

    print("RemoteTouchSurface.isEligibleRemoteSurface")

    // Siri Remote 1st-gen (A1513), ~3460x3640, external.
    expectTrue(
        RemoteTouchSurface.isEligibleRemoteSurface(width: 3460, height: 3640, builtIn: false),
        "Siri Remote surface (3460x3640, external) is eligible"
    )

    // Magic Trackpad 2, ~15600x11040, external. This is the exact device that was wrongly
    // adopted as "the remote" before the fix.
    expectFalse(
        RemoteTouchSurface.isEligibleRemoteSurface(width: 15600, height: 11040, builtIn: false),
        "Magic Trackpad 2 surface (15600x11040, external) is NOT eligible"
    )

    // The original (2010) Magic Trackpad is physically smaller than the Magic Trackpad 2 but
    // still far larger than the remote; a conservative smaller-surface figure must still fail.
    expectFalse(
        RemoteTouchSurface.isEligibleRemoteSurface(width: 9000, height: 8000, builtIn: false),
        "Older/smaller Magic Trackpad surface (9000x8000, external) is NOT eligible"
    )

    // Even a hypothetically remote-sized surface must be rejected if it's built-in.
    expectFalse(
        RemoteTouchSurface.isEligibleRemoteSurface(width: 3460, height: 3640, builtIn: true),
        "Remote-sized but built-in surface is NOT eligible"
    )

    // Fail-closed on malformed readings.
    expectFalse(
        RemoteTouchSurface.isEligibleRemoteSurface(width: 0, height: 0, builtIn: false),
        "Zero dimensions are NOT eligible (fail closed)"
    )
    expectFalse(
        RemoteTouchSurface.isEligibleRemoteSurface(width: -1, height: 3640, builtIn: false),
        "Negative width is NOT eligible (fail closed)"
    )

    // Boundary: width * height == maxSurfaceArea exactly is inclusive; one unit above is not.
    expectTrue(
        RemoteTouchSurface.isEligibleRemoteSurface(width: 30_000_000, height: 1, builtIn: false),
        "Area exactly at threshold (30_000_000) is eligible"
    )
    expectFalse(
        RemoteTouchSurface.isEligibleRemoteSurface(width: 30_000_001, height: 1, builtIn: false),
        "Area one unit above threshold is NOT eligible"
    )

    if failures == 0 {
        print("PASSED (8/8)")
    } else {
        print("FAILED (\(failures) failure(s))")
    }
    return failures
}
