import SwiftUI
import AppKit

// MARK: - BackgroundPickerView

struct BackgroundPickerView: View {
    @Binding var selected: BackgroundStyle

    // Compact adaptive grid
    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(BackgroundStyle.all) { style in
                BackgroundThumbView(style: style, isSelected: selected.id == style.id)
                    .onTapGesture { selected = style }
            }
        }
    }
}

// MARK: - BackgroundThumbView

private struct BackgroundThumbView: View {
    let style: BackgroundStyle
    let isSelected: Bool

    private let size: CGFloat = 44

    var body: some View {
        ZStack {
            thumbnailContent
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Selection ring using native accent color
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                    lineWidth: isSelected ? 2.5 : 0.5
                )
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(style.displayName)
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        switch style {
        case .checkerboard:
            CheckerboardView(cellSize: 4)

        case .color(let color):
            Color(color)

        case .pattern(_, let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }
}

// MARK: - CheckerboardView
// Used both for the thumbnail AND the full-size background in ZoomableImageNSView.
// Properly tiles the pattern across the full bounds.

struct CheckerboardView: View {
    var cellSize: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            // Fill white base
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))

            let cols = Int(ceil(size.width  / cellSize)) + 1
            let rows = Int(ceil(size.height / cellSize)) + 1

            for row in 0..<rows {
                for col in 0..<cols {
                    guard (row + col) % 2 == 1 else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(Path(rect), with: .color(Color(white: 0.78)))
                }
            }
        }
    }
}
