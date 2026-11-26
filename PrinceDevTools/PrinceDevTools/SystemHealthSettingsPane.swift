import SwiftUI
import SystemHealth

/// Settings → System health: every threshold. A change is saved and evaluated at once by
/// `HealthMonitor.settings`; each stepper stops at its range.
struct SystemHealthSettingsPane: View {
    @Bindable var monitor: HealthMonitor

    var body: some View {
        Form {
            Section("Memory") {
                Picker("Red at pressure", selection: $monitor.settings.memoryRedLevel) {
                    Text("Critical").tag(MemoryLevel.critical)
                    Text("Warning").tag(MemoryLevel.warning)
                }
                SettingsNote("Critical is Apple's red. Warning also turns memory red on Apple's yellow.")
            }
            Section("CPU") {
                Stepper(
                    "Busier than \(monitor.settings.cpuPercent) %",
                    value: $monitor.settings.cpuPercent, in: HealthSettings.cpuPercentRange, step: 5)
                Stepper(
                    "For \(monitor.settings.cpuWindowMinutes) min",
                    value: $monitor.settings.cpuWindowMinutes, in: HealthSettings.cpuWindowRange, step: 1)
                Stepper(
                    "Or one process over \(monitor.settings.processCPUPercent) % of a core",
                    value: $monitor.settings.processCPUPercent, in: HealthSettings.processCPUPercentRange, step: 10)
                SettingsNote(
                    "CPU turns red once its average over the whole window passes the limit, or once one of your processes stays over that share of a core in every minute of the window.")
            }
            Section("Disk") {
                Stepper(
                    "Less than \(monitor.settings.diskFreeGB) GB free",
                    value: $monitor.settings.diskFreeGB, in: HealthSettings.diskFreeRange, step: 5)
            }
            Section("Processes") {
                Stepper(
                    "More than \(monitor.settings.processSharePercent) % of your process limit",
                    value: $monitor.settings.processSharePercent, in: HealthSettings.processShareRange, step: 5)
            }
        }
        .formStyle(.grouped)
    }
}
