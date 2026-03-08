import Foundation
import Observation

/// Persisted user preferences, stored in UserDefaults.
@Observable
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    // MARK: - VM

    /// CPU core count allocated to the VM (default: half of available)
    var vmCPUCount: Int {
        get { UserDefaults.standard.integer(forKey: "vmCPUCount").nonZero ?? max(2, ProcessInfo.processInfo.processorCount / 2) }
        set { UserDefaults.standard.set(newValue, forKey: "vmCPUCount") }
    }

    /// RAM in GiB allocated to the VM (default: 4 GiB)
    var vmMemoryGiB: Int {
        get { UserDefaults.standard.integer(forKey: "vmMemoryGiB").nonZero ?? 4 }
        set { UserDefaults.standard.set(newValue, forKey: "vmMemoryGiB") }
    }

    /// Disk storage allocated for the VM expansion layer in GiB (default: 64 GiB)
    var vmDiskGiB: Int {
        get { UserDefaults.standard.integer(forKey: "vmDiskGiB").nonZero ?? 64 }
        set { UserDefaults.standard.set(newValue, forKey: "vmDiskGiB") }
    }

    /// Whether to keep the VM running between game sessions (faster subsequent launches)
    var keepVMRunning: Bool {
        get { UserDefaults.standard.bool(forKey: "keepVMRunning") }
        set { UserDefaults.standard.set(newValue, forKey: "keepVMRunning") }
    }

    /// VM display width in pixels (default: 1920)
    var vmDisplayWidth: Int {
        get { UserDefaults.standard.integer(forKey: "vmDisplayWidth").nonZero ?? 1920 }
        set { UserDefaults.standard.set(newValue, forKey: "vmDisplayWidth") }
    }

    /// VM display height in pixels (default: 1080)
    var vmDisplayHeight: Int {
        get { UserDefaults.standard.integer(forKey: "vmDisplayHeight").nonZero ?? 1080 }
        set { UserDefaults.standard.set(newValue, forKey: "vmDisplayHeight") }
    }

    /// GitHub repo slug used to fetch Meridian base image releases, e.g. "aftrnd/meridian"
    var imageRepoSlug: String {
        get { UserDefaults.standard.string(forKey: "imageRepoSlug") ?? "aftrnd/meridian" }
        set { UserDefaults.standard.set(newValue, forKey: "imageRepoSlug") }
    }

    private init() {}
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
