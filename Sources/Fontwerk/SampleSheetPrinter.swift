import AppKit
import CoreText

/// Prints a sample sheet: for each font its name and the sample text in
/// several sizes. Inactive fonts print too, straight from their files.
@MainActor
enum SampleSheetPrinter {
    static let sizes: [CGFloat] = [10, 14, 24, 36]

    static func print(_ records: [FontRecord], sampleText: String) {
        guard !records.isEmpty else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.leftMargin = 40
        info.rightMargin = 40
        info.topMargin = 40
        info.bottomMargin = 40

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let text = makeText(records, sampleText: sampleText)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.isEditable = false
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(text)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            textView.setFrameSize(NSSize(width: width, height: ceil(used.height) + 20))
        }

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.jobTitle = records.count == 1 ? "Musterblatt \(records[0].fullName)" : "Fontwerk Musterblatt"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    private static func makeText(_ records: [FontRecord], sampleText: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let sample = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.paragraphSpacingBefore = 18
        headerStyle.paragraphSpacing = 4
        let lineStyle = NSMutableParagraphStyle()
        lineStyle.paragraphSpacing = 4
        lineStyle.lineBreakMode = .byTruncatingTail

        for record in records {
            var details = [record.format]
            if !record.versionText.isEmpty { details.append(record.versionText) }
            if !record.foundryText.isEmpty { details.append(record.foundryText) }
            result.append(NSAttributedString(
                string: "\(record.fullName)   \(details.joined(separator: " · "))\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 8, weight: .medium),
                    .foregroundColor: NSColor.darkGray,
                    .paragraphStyle: headerStyle,
                ]))
            for size in sizes {
                // CTFont and NSFont are the same object, so CoreText fonts
                // work as the font attribute.
                let font: Any = FontFaceCache.shared.font(for: record, size: size).map { $0 as Any }
                    ?? NSFont.systemFont(ofSize: size)
                result.append(NSAttributedString(
                    string: (sample.isEmpty ? record.fullName : sample) + "\n",
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.black,
                        .paragraphStyle: lineStyle,
                    ]))
            }
        }
        return result
    }
}
