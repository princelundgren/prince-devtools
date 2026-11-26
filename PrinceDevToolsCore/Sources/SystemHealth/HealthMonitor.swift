import Foundation
import Observation

/// Keeps ``readings``, ``status`` and ``culprits`` current, cheaply: one 60 s timer, a 2 s one only
/// while the panel is open, the memory-pressure and thermal events, and a process scan only when a
/// message appears or the panel opens on one, or on the 60 s tick while the machine was busy enough
/// in the last minute for one process to be at its clearing share of a core. Every scan runs at
/// background priority, and nothing waits on it.
///
/// Call ``start()`` once, and ``stop()`` before releasing the monitor; the app forwards the
/// system's sleep and wake and the panel's opening and closing.
@MainActor @Observable
public final class HealthMonitor {
    private static let tickInterval: TimeInterval = 60
    private static let tickTolerance: TimeInterval = 10
    private static let panelTickInterval: TimeInterval = 2
    private static let panelTickTolerance: TimeInterval = 0.2
    private static let cpuCulpritSpan = Duration.seconds(2)

    /// The latest reading of every metric.
    public private(set) var readings = HealthReadings()
    /// The cards and messages for ``readings`` under ``settings``.
    public private(set) var status: HealthStatus
    /// The process behind each shown message that has one; a cause's entry goes when its message does.
    public private(set) var culprits: [HealthCause: Culprit] = [:]
    /// The thresholds. Setting them saves them to the monitor's defaults and re-evaluates at once.
    public var settings: HealthSettings {
        didSet {
            settings.save(to: defaults)
            readings.cpu = cpuRing.average(over: settings.cpuWindow)
            readings.busyProcess = busiestProcess()
            evaluate()
        }
    }

    private let source: HealthSource
    private let defaults: UserDefaults
    @ObservationIgnored private var evaluator = HealthEvaluator()
    @ObservationIgnored private var cpuRing = CPURing()
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var panelTickTimer: Timer?
    @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isPanelOpen = false
    @ObservationIgnored private var culpritGeneration = 0
    @ObservationIgnored private var culpritSearches: [HealthCause: Task<Void, Never>] = [:]
    @ObservationIgnored private var busyTracker = BusyProcessTracker()
    @ObservationIgnored private var busyGeneration = 0
    @ObservationIgnored private var busyScan: Task<Void, Never>?

    /// A monitor that reads `source` and keeps its settings in `defaults`; it reads nothing until ``start()``.
    public init(source: HealthSource = .live, defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        let settings = HealthSettings(reading: defaults)
        self.settings = settings
        status = evaluator.evaluate(HealthReadings(), settings: settings)
    }

    var isPanelTimerArmed: Bool { panelTickTimer != nil }

    /// Reads everything, subscribes to the memory-pressure and thermal events and arms the 60 s timer.
    public func start() {
        readings.thermal = source.thermalLevel()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged() }
        }
        let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        memoryPressureSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.memoryEvent() }
        }
        memoryPressureSource.activate()
        self.memoryPressureSource = memoryPressureSource
        readProcessLimitAndPolledMetrics()
        appendCPUSample()
        evaluate()
        armTickTimer()
    }

    /// Stops both timers and both event subscriptions; a culprit search or process scan still running
    /// is discarded, and with it any busy process.
    public func stop() {
        disarmTimers()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        culpritGeneration += 1
        forgetBusyProcesses()
    }

    /// Stops both timers until ``wake()``; a culprit search or process scan still running is discarded.
    public func sleep() {
        disarmTimers()
        culpritGeneration += 1
        forgetBusyProcesses()
    }

    /// Drops the CPU samples and the busy-process counts, and with them any CPU message, reads
    /// everything and re-arms the timers.
    public func wake() {
        cpuRing.removeAll()
        forgetBusyProcesses()
        readEverything()
        appendCPUSample()
        evaluate()
        armTickTimer()
        if isPanelOpen { armPanelTickTimer() }
    }

    /// Reads the polled metrics at once, so the panel opens on current values, arms the 2 s timer and
    /// looks for the culprit of every message shown.
    public func panelOpened() {
        isPanelOpen = true
        let shownBefore = status.messages.map(\.cause)
        panelTick()
        armPanelTickTimer()
        for cause in shownBefore where isShown(cause) { startCulpritSearch(for: cause) }
    }

    /// Stops the 2 s timer; a culprit search still running is discarded.
    public func panelClosed() {
        isPanelOpen = false
        panelTickTimer?.invalidate()
        panelTickTimer = nil
        culpritGeneration += 1
    }

    func tick() {
        appendCPUSample()
        readPolledMetrics()
        trackBusyProcesses()
        evaluate()
    }

    func panelTick() {
        readPolledMetrics()
        evaluate()
    }

    func memoryEvent() {
        readings.memory = source.memoryLevel()
        evaluate()
    }

    func thermalChanged() {
        readings.thermal = source.thermalLevel()
        evaluate()
    }

    func culpritSearchesFinished() async {
        for search in culpritSearches.values { await search.value }
    }

    func busyScanFinished() async {
        await busyScan?.value
    }

    private func readEverything() {
        readings.thermal = source.thermalLevel()
        readProcessLimitAndPolledMetrics()
    }

    private func readProcessLimitAndPolledMetrics() {
        readings.processLimit = source.processLimit()
        readPolledMetrics()
    }

    private func readPolledMetrics() {
        readings.processCount = source.processCount()
        readings.diskFreeBytes = source.diskFreeBytes()
        readings.swapUsedBytes = source.swapUsedBytes()
        readings.memory = source.memoryLevel()
    }

    private func appendCPUSample() {
        if let ticks = source.cpuTicks() {
            cpuRing.append(CPUSample(ticks: ticks, time: source.now()))
        }
        readings.cpu = cpuRing.average(over: settings.cpuWindow)
    }

    /// Scans the user's processes when the last minute's busy time could hold one at its clearing
    /// share of a core; otherwise no process can be, so the counts go.
    private func trackBusyProcesses() {
        let clearingCores = (Double(settings.processCPUPercent) - BusyProcessTracker.clearMarginPercent) / 100
        guard let busyCores = cpuRing.busyCoresInLastInterval(ticksPerSecond: source.ticksPerSecond),
            busyCores >= clearingCores
        else {
            forgetBusyProcesses()
            return
        }
        let generation = busyGeneration
        busyScan = Task(priority: .background) { [source] in
            let (cpuTimes, time) = await Self.timedCPUTimes(source)
            guard generation == busyGeneration else { return }
            busyTracker.record(cpuTimes, at: time, timebase: source.timebase)
            readings.busyProcess = busiestProcess()
            evaluate()
        }
    }

    private func busiestProcess() -> BusyProcess? {
        busyTracker.busiest(over: settings.processCPUPercent, window: settings.cpuWindow, name: source.processName)
    }

    private func forgetBusyProcesses() {
        busyGeneration += 1
        busyTracker.reset()
        readings.busyProcess = nil
    }

    private func evaluate() {
        let shownBefore = Set(status.messages.map(\.cause))
        status = evaluator.evaluate(readings, settings: settings)
        let shownNow = Set(status.messages.map(\.cause))
        for cause in shownBefore.subtracting(shownNow) { culprits[cause] = nil }
        for cause in shownNow.subtracting(shownBefore) { startCulpritSearch(for: cause) }
    }

    private func isShown(_ cause: HealthCause) -> Bool {
        status.messages.contains { $0.cause == cause }
    }

    private func startCulpritSearch(for cause: HealthCause) {
        guard let search = culpritSearch(for: cause) else { return }
        let generation = culpritGeneration
        culpritSearches[cause] = Task(priority: .background) {
            let culprit = await search()
            guard generation == culpritGeneration, isShown(cause) else { return }
            culprits[cause] = culprit
        }
    }

    private func culpritSearch(for cause: HealthCause) -> (@MainActor () async -> Culprit?)? {
        switch cause {
        case .memory: { [source] in CulpritFinder.memory(await Self.scan(source)) }
        case .processes: { [source] in CulpritFinder.processes(await Self.scan(source)) }
        case .cpu: { [source] in await Self.cpuCulprit(source) }
        case .disk, .busyProcess, .thermal: nil
        }
    }

    private static func cpuCulprit(_ source: HealthSource) async -> Culprit? {
        let before = await scan(source)
        let ticksBefore = source.cpuTicks()
        let timeBefore = source.now()
        await source.pause(cpuCulpritSpan)
        let after = await scan(source)
        let ticksAfter = source.cpuTicks()
        let timeAfter = source.now()
        guard let ticksBefore, let ticksAfter else { return nil }

        let busyTicks = ticksAfter.busyAndTotal(since: ticksBefore).busy
        return CulpritFinder.cpu(
            before: before, after: after, interval: timeAfter - timeBefore, timebase: source.timebase,
            machineBusyNanoseconds: busyTicks * 1_000_000_000 / UInt64(source.ticksPerSecond))
    }

    @concurrent
    private static func scan(_ source: HealthSource) async -> [ProcessUsage] {
        source.processUsages()
    }

    @concurrent
    private static func timedCPUTimes(_ source: HealthSource) async -> ([pid_t: UInt64], ContinuousClock.Instant) {
        let cpuTimes = source.processCPUTimes()
        return (cpuTimes, source.now())
    }

    private func armTickTimer() {
        tickTimer?.invalidate()
        tickTimer = makeTimer(interval: Self.tickInterval, tolerance: Self.tickTolerance) { $0.tick() }
    }

    private func armPanelTickTimer() {
        panelTickTimer?.invalidate()
        panelTickTimer = makeTimer(interval: Self.panelTickInterval, tolerance: Self.panelTickTolerance) {
            $0.panelTick()
        }
    }

    private func disarmTimers() {
        tickTimer?.invalidate()
        tickTimer = nil
        panelTickTimer?.invalidate()
        panelTickTimer = nil
    }

    private func makeTimer(
        interval: TimeInterval, tolerance: TimeInterval, action: @escaping @MainActor (HealthMonitor) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
