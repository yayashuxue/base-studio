import BaseStudioCore
import SwiftUI

struct RecordingsListView: View {
    @ObservedObject var vm: RecordingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings")
                    .font(.title3.bold())
                Spacer()
                Button(action: vm.refreshLibrary) {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain).help("Refresh")
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            Divider().opacity(0.2)

            if vm.library.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No recordings yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.library) { entry in
                            RecordingRow(
                                entry: entry,
                                isSelected: vm.editorState?.bundleURL == entry.id,
                                onOpen: { vm.openRecording(entry) },
                                onDelete: { vm.deleteRecording(entry) },
                                onRename: { newName in vm.renameRecording(entry, to: newName) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 240)
        .background(Color.black.opacity(0.45))
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

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: entry.hasPolishedExport
                      ? "wand.and.stars.inverse" : "rectangle.stack")
                    .foregroundStyle(entry.hasPolishedExport
                                     ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    if isRenaming {
                        TextField("Name", text: $draftName, onCommit: commitRename)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    } else {
                        Text(entry.displayName)
                            .lineLimit(1)
                            .font(.system(size: 12))
                    }
                    Text(Self.dateFormatter.string(from: entry.modifiedAt))
                        .lineLimit(1)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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
