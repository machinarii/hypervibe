//
//  main.swift
//  HyperVibe
//
//  Application entry point
//

import AppKit

// Create the application instance
let app = NSApplication.shared

// Create and set the delegate
let delegate = AppDelegate()
app.delegate = delegate

// Run the application
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
