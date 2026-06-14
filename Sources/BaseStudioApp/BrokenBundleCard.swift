import AppKit
import BaseStudioCore
import SwiftUI

/// Full-pane recovery card for recordings whose saved bundle is incomplete.
struct BrokenBundleCard: View {
    let bundle: ProjectBundle
    let message: String
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hoveringDelete = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: BS.Space.xl)

            VStack(alignment: .leading, spacing: BS.Space.regular) {
                HStack(alignment: .firstTextBaseline, spacing: BS.Space.snug) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BS.Color.statusWarn)
                        .symbolRenderingMode(.hierarchical)
                        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] + 2 }

                    VStack(alignment: .leading, spacing: BS.Space.micro) {
                        Text("Recording incomplete")
                            .font(BS.Font.title)
                            .foregroundStyle(BS.Color.textPrimary)
                        Text(humanizedBody)
                            .font(BS.Font.label)
                            .foregroundStyle(BS.Color.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                bundleMetaRow
                    .padding(.horizontal, BS.Space.snug)
                    .padding(.vertical, BS.Space.tight)
                    .background(
                        RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                            .fill(BS.Color.surfaceLit.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                            .strokeBorder(BS.Color.hairline, lineWidth: 1)
                    )

                HStack(spacing: BS.Space.tight) {
                    Button(action: onReveal) {
                        HStack(spacing: BS.Space.gap) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Reveal in Finder")
                                .font(BS.Font.labelStrong)
                        }
                        .foregroundStyle(BS.Color.onAccent)
                        .padding(.horizontal, BS.Space.snug)
                        .padding(.vertical, BS.Space.tight)
                        .bsAccentButton()
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)

                    Button(action: onDelete) {
                        HStack(spacing: BS.Space.gap) {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Delete recording")
                                .font(BS.Font.labelStrong)
                        }
                        .foregroundStyle(
                            hoveringDelete ? BS.Color.recordingRed : BS.Color.textPrimary
                        )
                        .padding(.horizontal, BS.Space.snug)
                        .padding(.vertical, BS.Space.tight)
                        .background(
                            RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                                .fill(BS.Color.surfaceRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: BS.Radius.chip, style: .continuous)
                                .strokeBorder(
                                    hoveringDelete
                                        ? BS.Color.recordingRed.opacity(0.55)
                                        : BS.Color.hairline,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringDelete = $0 }
                    .animation(BS.Motion.snap, value: hoveringDelete)
                }

                Text(message)
                    .font(BS.Font.caption)
                    .foregroundStyle(BS.Color.textTertiary)
                    .padding(.top, BS.Space.micro)
            }
            .padding(BS.Space.section)
            .frame(maxWidth: 480, alignment: .leading)
            .bsSurface(radius: BS.Radius.panel, raised: true)

            Spacer(minLength: BS.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, BS.Space.loose)
    }

    private var humanizedBody: String {
        "Some files are missing from this recording, so it can't be opened. "
            + "You can keep the folder around to inspect it, or delete it and re-record."
    }

    private var bundleMetaRow: some View {
        HStack(spacing: BS.Space.snug) {
            Image(systemName: "doc.fill")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(BS.Color.textTertiary)
            Text(bundle.url.lastPathComponent)
                .font(BS.Font.mono)
                .foregroundStyle(BS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: BS.Space.snug)
            Text(bundleSizeLabel)
                .font(BS.Font.mono)
                .foregroundStyle(BS.Color.textTertiary)
        }
    }

    private var bundleSizeLabel: String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundle.url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "-"
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
