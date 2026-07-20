//
//  main.swift (Tests)
//  HyperVibe
//
//  Entry point for the standalone RemoteTouchSurface tests. See Tests/run-tests.sh.
//

import Darwin

exit(runRemoteTouchSurfaceTests() == 0 ? 0 : 1)
