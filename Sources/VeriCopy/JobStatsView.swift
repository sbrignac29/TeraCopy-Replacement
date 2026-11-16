import Charts
import SwiftUI
import VeriCopyCore

/// Alternative to the file list: live counters plus a read/write throughput graph.
/// Read = bytes streamed in (source during copy, read-back during verification);
/// Write = bytes streamed out to the destination. During a verify pass the write
/// line drops to zero while the read line carries on — that's the read-back.
struct JobStatsView: View {
    @ObservedObject var job: TransferJob

    /// Chart lines use colors no status uses, so a line is never read as "verified" (green)
    /// or "copying" (blue). Read is also dashed, so the two lines differ by more than color
    /// and both stay visible when they overlap. Indigo measures 5.09:1 light / 4.75:1 dark,
    /// purple 4.17:1 / 4.59:1.
    private static let writeColor = Color.indigo
    private static let readColor = Color.purple
    private static let writeStroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    private static let readStroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 4])

    var body: some View {
        let counts = job.statusCounts

        VStack(spacing: 16) {
            HStack(spacing: 12) {
                StatTile(value: counts.copied, label: "Copied",
                         icon: "doc.on.doc.fill", color: StatusColor.copying)
                StatTile(value: counts.verified, label: "Verified",
                         icon: "checkmark.seal.fill", color: StatusColor.verified)
                StatTile(value: counts.failed, label: "Failed",
                         icon: failureSymbolName,
                         color: counts.failed > 0 ? StatusColor.failed : StatusColor.inactive)
                StatTile(value: counts.waiting, label: "Waiting",
                         icon: "clock", color: StatusColor.inactive)
            }
            .fixedSize(horizontal: false, vertical: true)

            totalsRow(counts)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Text("Transfer speed")
                            .font(.headline)
                        Spacer()
                        legendValue(label: "Read", color: Self.readColor, stroke: Self.readStroke,
                                    bps: job.readSpeedNow)
                        legendValue(label: "Write", color: Self.writeColor, stroke: Self.writeStroke,
                                    bps: job.writeSpeedNow)
                    }

                    // The graph fills the remaining vertical space (grows in a tall window),
                    // but has a small floor so it shrinks gracefully when the window is short —
                    // that's what keeps the header and footer from ever being clipped.
                    Group {
                        if job.speedHistory.isEmpty {
                            Text(job.isActive
                                 ? "Gathering samples…"
                                 : "Speeds are graphed here while the job runs.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            speedChart
                        }
                    }
                    .frame(minHeight: 90, maxHeight: .infinity)
                }
                .padding(6)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var speedChart: some View {
        let start = job.speedHistory.first?.time ?? Date()
        return Chart {
            ForEach(job.speedHistory) { sample in
                LineMark(
                    x: .value("Seconds", sample.time.timeIntervalSince(start)),
                    y: .value("MB/s", max(0, sample.readBps) / 1_048_576),
                    series: .value("Direction", "Read")
                )
                .foregroundStyle(by: .value("Direction", "Read"))
                .interpolationMethod(.monotone)
                .lineStyle(Self.readStroke)
            }
            ForEach(job.speedHistory) { sample in
                LineMark(
                    x: .value("Seconds", sample.time.timeIntervalSince(start)),
                    y: .value("MB/s", max(0, sample.writeBps) / 1_048_576),
                    series: .value("Direction", "Write")
                )
                .foregroundStyle(by: .value("Direction", "Write"))
                .interpolationMethod(.monotone)
                .lineStyle(Self.writeStroke)
            }
        }
        .chartForegroundStyleScale(["Read": Self.readColor, "Write": Self.writeColor])
        .chartLegend(.hidden) // the live legend values above stand in for it
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxisLabel("MB/s")
        .chartXAxisLabel("seconds", alignment: .trailing)
        .animation(.easeOut(duration: 0.35), value: job.speedHistory.count)
    }

    /// The swatch is a short stretch of the line itself, dash and all, so the legend matches
    /// the chart without relying on color.
    private func legendValue(label: String, color: Color, stroke: StrokeStyle, bps: Double) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 1, y: 4))
                path.addLine(to: CGPoint(x: 17, y: 4))
            }
            .stroke(color, style: stroke)
            .frame(width: 18, height: 8)
            .accessibilityHidden(true)
            Text(label).foregroundStyle(.secondary)
            Text(bps > 0 ? "\(bytes(Int64(bps)))/s" : "—")
                .monospacedDigit()
                .frame(minWidth: 62, alignment: .leading)
        }
        .font(.callout)
    }

    /// Fixed-layout totals so nothing reflows as counts change during a run. Each metric keeps
    /// a reserved width, so ticking byte values never shove neighbouring text sideways.
    private func totalsRow(_ counts: TransferJob.StatusCounts) -> some View {
        HStack(spacing: 24) {
            metric(value: "\(counts.total)", label: counts.total == 1 ? "file" : "files", minWidth: 40)
            metric(value: bytes(job.readBytesTotal), label: "read", minWidth: 78)
            metric(value: bytes(job.writeBytesTotal), label: "written", minWidth: 78)
            if counts.skipped > 0 {
                metric(value: "\(counts.skipped)", label: "skipped", minWidth: 56)
            }
        }
    }

    private func metric(value: String, label: String, minWidth: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.callout).fontWeight(.medium)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: minWidth)
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text("\(value)")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
