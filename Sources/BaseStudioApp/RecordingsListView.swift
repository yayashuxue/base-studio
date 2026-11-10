import BaseStudioCore
import SwiftUI

/// Left-rail list of saved recordings.
///
/// Studio Console aesthetic: subdued surface, uppercase section header,
/// monospaced timestamp, polished accent indicator on rows that already have
/// a polished export.
struct RecordingsListView: View {
    @ObservedObject var vm: RecordingViewModel
    @State private var rowFrames: [URL: CGRect] = [:]
    @State private var marquee: CGRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BS.Space.tight) {
                if vm.librarySelection.count > 1 {
                    Text("\(vm.librarySelection.count) selected")
                        .font(BS.Font.labelStrong)
                        .foregroundStyle(BS.Color.textPrimary)
                    Spacer()
                    Button(action: vm.trashSelectedRecordings) {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BS.Color.statusError)
                    .help("Move to Trash")
                    Button(action: vm.clearRecordingSelection) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BS.Color.textSecondary)
                    .help("Clear selection")
                } else {
                    Text("Recordings")
                        .bsSectionHeader()
                    Spacer()
                    Button(action: vm.selectAllRecordings) {
                        Image(systemName: "checklist").font(.system(size: 11))
                            .foregroundStyle(BS.Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Select all (⌘A)")
                }
                Button(action: vm.refreshLibrary) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(BS.Color.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, BS.Space.regular)
            .padding(.top, BS.Space.regular)
            .padding(.bottom, BS.Space.snug)

            Rectangle().fill(BS.Color.hairline).frame(height: 1)

            if vm.library.isEmpty {
                VStack(spacing: BS.Space.tight) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(BS.Color.textTertiary)
                    Text("No recordings yet")
                        .font(BS.Font.caption)
                        .foregroundStyle(BS.Color.textSecondary)
                    Text("Hit ⌘R to start one")
                        .font(BS.Font.caption)
                        .foregroundStyle(BS.Color.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(vm.library) { entry in
                            RecordingRow(
                                entry: entry,
                                isSelected: vm.librarySelection.count > 1
                                    ? vm.librarySelection.contains(entry.id)
                                    : vm.editorState?.bundleURL == entry.id,
                                onOpen: { vm.clickRecording(entry, modifiers: NSEvent.modifierFlags) },
                                onDelete: {
                                    // Context menu on a selected row acts on the whole selection.
                                    if vm.librarySelection.count > 1, vm.librarySelection.contains(entry.id) {
                                        vm.trashSelectedRecordings()
                                    } else {
                                        vm.librarySelection = [entry.id]
                                        vm.trashSelectedRecordings()
                                    }
                                },
                                onRename: { newName in vm.renameRecording(entry, to: newName) }
                            )
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RowFrames.self,
                                                       value: [entry.id: g.frame(in: .named("recordings"))])
                            })
                        }
                    }
                    .padding(.horizontal, BS.Space.tight)
                    .padding(.vertical, BS.Space.tight)
                    .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
                    .coordinateSpace(name: "recordings")
                    // Drag a box (starting anywhere in the list) to select rows.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named("recordings"))
                            .onChanged { v in
                                let box = CGRect(x: min(v.startLocation.x, v.location.x),
                                                 y: min(v.startLocation.y, v.location.y),
                                                 width: abs(v.location.x - v.startLocation.x),
                                                 height: abs(v.location.y - v.startLocation.y))
                                marquee = box
                                let hit = Set(rowFrames.filter { $0.value.intersects(box) }.map(\.key))
                                vm.librarySelection = NSEvent.modifierFlags.contains(.command)
                                    ? vm.librarySelection.union(hit) : hit
                            }
                            .onEnded { _ in marquee = nil }
                    )
                    .overlay(alignment: .topLeading) {
                        if let m = marquee {
                            Rectangle()
                                .fill(BS.Color.accent.opacity(0.12))
                                .overlay(Rectangle().strokeBorder(BS.Color.accent.opacity(0.6), lineWidth: 1))
                                .frame(width: m.width, height: m.height)
                                .offset(x: m.minX, y: m.minY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .focusable()
                .onCommand(#selector(NSResponder.selectAll(_:))) { vm.selectAllRecordings() }
                .onDeleteCommand { if !vm.librarySelection.isEmpty { vm.trashSelectedRecordings() } }
                .onExitCommand { vm.clearRecordingSelection() }
            }
        }
        .frame(width: 248)
        .background(BS.Color.surface.opacity(0.65))
    }
}

private struct RowFrames: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct RecordingRow: View {
    let entry: RecordingsLibrary.Entry
    let isSelected: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    @State private var isRenaming = false
    @State private var draftName: String = ""
    @State private var isHover = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: BS.Space.snug) {
                Image(systemName: entry.hasPolishedExport
                      ? "wand.and.stars.inverse" : "rectangle.stack")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(entry.hasPolishedExport
                                     ? BS.Color.accent : BS.Color.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    if isRenaming {
                        TextField("Name", text: $draftName, onCommit: commitRename)
                            .textFieldStyle(.roundedBorder)
                            .font(BS.Font.label)
                    } else {
                        Text(entry.displayName)
                            .lineLimit(1)
                            .font(BS.Font.label)
                            .foregroundStyle(isSelected ? BS.Color.textPrimary : BS.Color.textSecondary)
                    }
                    Text(Self.dateFormatter.string(from: entry.modifiedAt))
                        .lineLimit(1)
                        .font(BS.Font.mono)
                        .foregroundStyle(BS.Color.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BS.Space.tight + 2)
            .padding(.vertical, BS.Space.gap)
            .background(rowBackground)
            .overlay(rowBorder)
        }
        .buttonStyle(.plain)
        .onHover { isHover = $0 }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Rename") {
                draftName = entry.displayName
                isRenaming = true
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.id])
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let fill: Color = {
            if isSelected { return BS.Color.accent.opacity(0.18) }
            if isHover    { return BS.Color.surfaceLit }
            return Color.clear
        }()
        RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
            .fill(fill)
    }
    @ViewBuilder
    private var rowBorder: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                .strokeBorder(BS.Color.accent.opacity(0.45), lineWidth: 1)
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != entry.displayName {
            onRename(trimmed)
        }
        isRenaming = false
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
