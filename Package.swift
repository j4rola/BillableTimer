// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BillableTimer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BillableTimer",
            path: "Sources/BillableTimer"
        )
    ]
)
