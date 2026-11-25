import Foundation
import Observation

/// Keeps ``readings`` and ``status`` current, cheaply: one 60 s timer, a 2 s one only while the
/// panel is open, and the memory-pressure and thermal events.
///
/// Call ``start()`` once, and ``stop()`` before releasing the monitor; the app forwards the
/// system's sleep and wake and the panel's opening and closing.
@MainActor @Observable
public final class HealthMonitor {
    private static let tickInterval: TimeInterval = 60
    private static let tickTolerance: TimeInterval = 10
    private static let panelTickInterval: TimeInterval = 2
    private static let panelTickTolerance: TimeInterval = 0.2

    /// The latest reading of every metric.
    public private(set) var readings = HealthReadings()
    /// The cards and messages for ``readings`` under ``settings``.
    public private(set) var status: HealthStatus
    /// The thresholds. Setting them saves them to the monitor's defaults and re-evaluates at once.
    public var settings: HealthSettings {
        didSet {
            settings.save(to: defaults)
            readings.cpu = cpuRing.average(over: settings.cpuWindow)
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

    /// Stops both timers and both event subscriptions.
    public func stop() {
        disarmTimers()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    /// Stops both timers until ``wake()``.
    public func sleep() {
        disarmTimers()
    }

    /// Drops the CPU samples, and with them any CPU message, reads everything and re-arms the timers.
    public func wake() {
        cpuRing.removeAll()
        readEverything()
        appendCPUSample()
        evaluate()
        armTickTimer()
        if isPanelOpen { armPanelTickTimer() }
    }

    /// Arms the 2 s timer.
    public func panelOpened() {
        isPanelOpen = true
        armPanelTickTimer()
    }

    /// Stops the 2 s timer.
    public func panelClosed() {
        isPanelOpen = false
        panelTickTimer?.invalidate()
        panelTickTimer = nil
    }

    func tick() {
        appendCPUSample()
        readPolledMetrics()
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

    private func evaluate() {
        status = evaluator.evaluate(readings, settings: settings)
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
