import SwiftUI

// MARK: - InfoButton
// Native popover info button using SF Symbol info.circle

private struct InfoButton: View {
    let text: String
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(minWidth: 200, maxWidth: 260)
        }
        .help(text)
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    @Bindable var document: ImageDocument

    var body: some View {
        VStack(spacing: 0) {
            List {
                // Auto / Manual mode picker — segmented control
                Section(header: Text("Mode")) {
                    Picker("", selection: $document.compressionMode) {
                        ForEach(CompressionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .collapsible(false)

                // Auto mode description
                if document.compressionMode == .auto {
                    Section {
                        Text("Uses minimum palette to achieve the chosen perceptual quality.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .collapsible(false)
                }

                // Mode-specific controls
                switch document.compressionMode {
                case .auto:
                    autoSection
                case .manual:
                    manualSection
                }

                // Resize / Upscale — shown in both modes
                resizeSection
            }
            .listStyle(.sidebar)

            Divider()

            // Background picker — content-sized
            VStack(alignment: .leading, spacing: 6) {
                Text("Background")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                BackgroundPickerView(selected: $document.selectedBackground)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: Resize

    // Resize snap points: below 100% = downsample, above 100% = AI upscale (4x then downsample)
    private static let resizeSteps: [(label: String, value: Int)] = [
        ("25%", 25), ("50%", 50), ("75%", 75), ("100%", 100),
        ("1.5×", 150), ("2×", 200), ("3×", 300), ("4×", 400),
    ]

    @ViewBuilder
    private var resizeSection: some View {
        Section {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Resize")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("\(document.resizedWidth) × \(document.resizedHeight)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        if document.resizePercent > 100 {
                            Text("AI")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.blue, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                }
                .padding(.trailing, 4)

                // Stepped slider that snaps to predefined values
                let steps = Self.resizeSteps
                let currentIndex = Binding<Double>(
                    get: {
                        // Find closest step index
                        let idx = steps.enumerated().min(by: { abs($0.element.value - document.resizePercent) < abs($1.element.value - document.resizePercent) })?.offset ?? 2
                        return Double(idx)
                    },
                    set: { newIdx in
                        let idx = max(0, min(steps.count - 1, Int(newIdx.rounded())))
                        document.resizePercent = steps[idx].value
                    }
                )
                Slider(value: currentIndex, in: 0...Double(steps.count - 1), step: 1) {
                    EmptyView()
                }

                // Tick labels — positioned to align with macOS slider track stops
                // macOS NSSlider has ~8pt internal padding on each side
                GeometryReader { geo in
                    let count = steps.count
                    let sliderPad: CGFloat = 8
                    let trackStart = sliderPad
                    let trackEnd = geo.size.width - sliderPad
                    let trackWidth = trackEnd - trackStart
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        let fraction = count > 1 ? CGFloat(idx) / CGFloat(count - 1) : 0.5
                        let position = trackStart + trackWidth * fraction
                        Text(step.label)
                            .font(.system(size: 8))
                            .foregroundStyle(document.resizePercent == step.value ? .primary : .tertiary)
                            .fixedSize()
                            .position(x: position, y: 6)
                    }
                }
                .frame(height: 14)

                if document.resizePercent > 100 {
                    Text("AI upscale via Real-ESRGAN")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .collapsible(false)
    }

    // MARK: Auto Mode

    @ViewBuilder
    private var autoSection: some View {
        Section {
            VStack(spacing: 4) {
                HStack {
                    Text("Quality")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(document.autoQuality)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Slider(value: Binding(
                    get: { Double(document.autoQuality) },
                    set: { document.autoQuality = Int($0) }
                ), in: 0...100) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("0").font(.caption).foregroundStyle(.primary)
                } maximumValueLabel: {
                    Text("100").font(.caption).foregroundStyle(.primary)
                }
            }
        }
        .collapsible(false)

        Section(header: Text("Options")) {
            Toggle(isOn: $document.ditheringEnabled) {
                HStack(spacing: 8) {
                    Label("Dithering", systemImage: "circle.grid.3x3")
                    InfoButton(text: "Best for photos and gradients — smooths color transitions. Skip for logos, icons, or flat-color art where it adds noise without benefit.")
                }
            }
            .toggleStyle(.switch)
        }
        .collapsible(false)
    }

    // MARK: Manual Mode

    @ViewBuilder
    private var manualSection: some View {
        Section {
            VStack(spacing: 4) {
                HStack {
                    Text("Colors")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Button {
                        document.autoDetectColors()
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Auto-detect optimal color count")
                    .disabled(document.sourceImage == nil)
                    Spacer()
                    Text(document.colorsLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Slider(value: $document.colorsBitDepth, in: 1...9, step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("2").font(.caption).foregroundStyle(.primary)
                } maximumValueLabel: {
                    Text("256").font(.caption).foregroundStyle(.primary)
                }
            }
        }
        .collapsible(false)

        Section(header: Text("Options")) {
            LabeledContent {
                Picker("", selection: $document.speed) {
                    Text("Slow (best)").tag(1)
                    Text("Balanced").tag(3)
                    Text("Fast").tag(6)
                    Text("Fastest").tag(11)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 120)
            } label: {
                HStack(spacing: 6) {
                    Label("Speed", systemImage: "gauge.with.needle")
                    InfoButton(text: "Controls palette accuracy. Slower = more precise colors but not always smaller. Rarely needs changing.")
                }
            }

            LabeledContent {
                Picker("", selection: $document.posterizeBits) {
                    Text("Off").tag(0)
                    Text("1 bit").tag(1)
                    Text("2 bits").tag(2)
                    Text("3 bits").tag(3)
                    Text("4 bits").tag(4)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 120)
            } label: {
                HStack(spacing: 6) {
                    Label("Posterize", systemImage: "slider.horizontal.3")
                    InfoButton(text: "Truncates the least-significant color bits, forcing near-identical pixels to match exactly. Helps compression on flat-color images; avoid for photos.")
                }
            }

            Toggle(isOn: $document.ditheringEnabled) {
                HStack(spacing: 8) {
                    Label("Dithering", systemImage: "circle.grid.3x3")
                    InfoButton(text: "Best for photos and gradients — smooths color transitions. Skip for logos, icons, or flat-color art where it adds noise without benefit.")
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $document.deflateOptimizationEnabled) {
                HStack(spacing: 8) {
                    Label("Lossless deflate", systemImage: "cylinder.split.1x2")
                    InfoButton(text: "Repacks the compressed data stream more efficiently after quantization. Lossless — no quality loss. Typically saves an additional 10–20%.")
                }
            }
            .toggleStyle(.switch)
        }
        .collapsible(false)
    }

}
