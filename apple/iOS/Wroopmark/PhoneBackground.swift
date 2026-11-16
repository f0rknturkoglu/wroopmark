import BackgroundTasks
import Foundation

/// Work the iPhone does while nobody is looking: iOS runs it when it sees
/// fit, usually at night on the charger. Without it a big import (a data
/// download of a few thousand posts) would read its pictures, build its
/// meaning index and copy its pages only while the app is on screen.
enum PhoneBackground {
    /// Long work on the charger: OCR, meaning vectors, post details.
    static let process = "com.f0rknturkoglu.wroopmark.ios.process"
    /// A short visit now and then: sync with the other devices.
    static let refresh = "com.f0rknturkoglu.wroopmark.ios.refresh"

    /// Before the app finishes launching (iOS requires it).
    @MainActor
    static func register(_ model: PhoneModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: process, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            let work = Task { @MainActor in
                let done = await model.backgroundPass()
                task.setTaskCompleted(success: done)
                schedule()
            }
            task.expirationHandler = {
                work.cancel()
                Task { @MainActor in model.stopBackgroundWork() }
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refresh, using: nil) { task in
            let work = Task { @MainActor in
                await model.backgroundSync()
                task.setTaskCompleted(success: true)
                schedule()
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Asks iOS for the next visits; a request already waiting is replaced.
    static func schedule() {
        let long = BGProcessingTaskRequest(identifier: process)
        long.requiresExternalPower = true
        long.requiresNetworkConnectivity = false
        long.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(long)

        let short = BGAppRefreshTaskRequest(identifier: refresh)
        short.earliestBeginDate = .now.addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(short)
    }
}

extension PhoneModel {
    /// Pictures and meaning vectors waiting, until done or iOS takes the time back.
    /// True when the work ran to its end.
    func backgroundPass() async -> Bool {
        guard await core.ensureOpen() else { return false }
        await syncNow()
        _ = try? await core.run(.kickMedia)
        startOCR()
        startEmbedding()
        // Page copies stay for when the app is open: a web view in the
        // background may be held back, and a copy that fails counts as a try.
        while isBackgroundWorking, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
        }
        let finished = !Task.isCancelled
        await syncNow()
        _ = try? await core.run(.call("pause", [:]))
        return finished
    }

    func backgroundSync() async {
        guard await core.ensureOpen() else { return }
        await syncNow()
        await OnThisDay.notifyIfDue(core: core)
        _ = try? await core.run(.call("pause", [:]))
    }

    func stopBackgroundWork() {
        stopOCR()
        stopEmbedding()
        stopPageCopies()
        Task { _ = try? await core.run(.call("pause", [:])) }
    }
}
