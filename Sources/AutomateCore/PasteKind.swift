import AppKit

/// What's on the clipboard, as far as pasting into a message goes.
public enum PasteKind: Equatable {
    case files([URL]), image, text

    public static func classify(_ pb: NSPasteboard) -> PasteKind {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil) else { return .text }
        // Text copied from Pages/Word/web pages often carries a picture of itself too: that's text.
        // A browser's "Copy Image" may add the image's address; that's still an image.
        let string = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if string.isEmpty { return .image }
        let isLink = !string.contains(where: \.isWhitespace) && (string.hasPrefix("http://") || string.hasPrefix("https://"))
        return isLink ? .image : .text
    }
}
