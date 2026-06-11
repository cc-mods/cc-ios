// swift-tools-version:5.9
import PackageDescription

// cc-ios shared host + macOS proof harness.
//
// `CCWebHost` is the cross-platform (iOS + macOS) WebKit layer: the custom-scheme
// file server and the JS bootstrap that makes CrossCode boot as a browser web app.
// The iOS app target (generated via XcodeGen, see app/) consumes the SAME sources,
// so anything proven by the macOS harness carries directly to the device build.
let package = Package(
    name: "cc-ios",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "CCWebHost", targets: ["CCWebHost"]),
        .executable(name: "webkit-harness", targets: ["webkit-harness"])
    ],
    targets: [
        .target(
            name: "CCWebHost",
            path: "Shared/CCWebHost"
        ),
        .executableTarget(
            name: "webkit-harness",
            dependencies: ["CCWebHost"],
            path: "tools/webkit-harness/Sources/Harness"
        )
    ]
)
