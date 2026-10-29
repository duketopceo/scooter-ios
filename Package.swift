// swift-tools-version: 6.0

import PackageDescription

// xtool builds the app on Linux from this package (`xtool dev build`). The XcodeGen
// project (project.yml / Scooter.xcodeproj) stays the TestFlight path; both compile
// the same Scooter/ sources.
let package = Package(
    name: "Scooter",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        // An xtool project contains exactly one library product: the app.
        .library(name: "Scooter", targets: ["Scooter"]),
    ],
    targets: [
        .target(
            name: "Scooter",
            path: "Scooter",
            exclude: ["Info.plist", "Info.xtool.plist", "Assets.xcassets"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
