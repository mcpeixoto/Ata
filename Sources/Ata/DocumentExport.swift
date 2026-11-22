import CoreGraphics
import CoreText
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
private typealias ExportFont = NSFont
private typealias ExportColor = NSColor
#else
import UIKit
private typealias ExportFont = UIFont
private typealias ExportColor = UIColor
#endif

/// What a meeting exports as: the user's notes, the summary, and the transcript
/// with a time and a speaker on each line.
struct ExportDocument: Equatable, Sendable {
    var title: String
    var notes: String
    var summary: String
    var lines: [ExportLine]
}

struct ExportLine: Equatable, Sendable {
    var startMs: Int
    var speaker: String
    var isMe: Bool
    var text: String
}

/// PDF and Word for one meeting. The PDF is laid out with Core Graphics, one
/// page frame at a time: ImageRenderer draws a single view into a single image,
/// and a long transcript has to break between lines. Word is a zip of Office
/// Open XML, written here so the app takes no new dependency.
enum DocumentExport {
    /// `.docx`. Falls back to a generic file when the system has no such type.
    static let wordType: UTType = UTType("org.openxmlformats.wordprocessingml.document")
        ?? UTType(filenameExtension: "docx")
        ?? .data

    static func pdf(_ document: ExportDocument) -> Data {
        let text = attributed(document)
        let data = NSMutableData()
        guard !text.string.isEmpty, let consumer = CGDataConsumer(data: data) else { return Data() }
        var box = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let content = box.insetBy(dx: margin, dy: margin)
        var location = 0
        let total = text.length
        var pages = 0
        while location < total && pages < 200 {
            context.beginPDFPage(nil)
            let path = CGPath(rect: content, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            pages += 1
            let next = visible.location + visible.length
            if visible.length <= 0 || next <= location { break }
            location = next
        }
        context.closePDF()
        return data as Data
    }

    static func pageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }

    static func docx(_ document: ExportDocument) -> Data {
        let xml = documentXML(document)
        let entries = [
            ZipStore.Entry(name: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            ZipStore.Entry(name: "_rels/.rels", data: Data(packageRels.utf8)),
            ZipStore.Entry(name: "word/_rels/document.xml.rels", data: Data(documentRels.utf8)),
            ZipStore.Entry(name: "word/styles.xml", data: Data(stylesXML.utf8)),
            ZipStore.Entry(name: "word/document.xml", data: Data(xml.utf8)),
        ]
        return ZipStore.archive(entries)
    }

    // MARK: PDF

    /// US Letter, in PDF points.
    private static let pageWidth: CGFloat = 612
    private static let pageHeight: CGFloat = 792
    /// Three-quarter inch. A page margin, not a control's padding.
    private static let margin: CGFloat = 54

    // Printed points, not Dynamic Type. They match the meeting window's title,
    // section and body sizes; a PDF page does not scale with the system text size.
    private static let titleSize: CGFloat = 20
    private static let headingSize: CGFloat = 15
    private static let bodySize: CGFloat = 13
    private static let timeSize: CGFloat = 11

    private static func attributed(_ document: ExportDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        append(document.title + "\n", size: titleSize, bold: true, color: ink, spacing: 12, to: result)
        if !document.notes.isEmpty {
            section(L("Notes"), body: document.notes, to: result)
        }
        if !document.summary.isEmpty {
            section(L("Summary"), body: document.summary, to: result)
        }
        if !document.lines.isEmpty {
            append(L("Transcript") + "\n", size: headingSize, bold: true, color: ink, spacing: 6, to: result)
            for line in document.lines {
                let row = NSMutableAttributedString()
                append(Transcriber.timestamp(line.startMs) + "  ", size: timeSize, bold: false, color: ink, spacing: 2, to: row)
                // Same sRGB as Theme.meTint and Theme.othersTint. Core Text takes a
                // platform color; SwiftUI.Color does not convert to one.
                append(line.speaker, size: bodySize, bold: true, color: line.isMe ? me : others, spacing: 2, to: row)
                append("  " + line.text + "\n", size: bodySize, bold: false, color: ink, spacing: 4, to: row)
                result.append(row)
            }
        }
        return result
    }

    private static func section(_ heading: String, body: String, to result: NSMutableAttributedString) {
        append(heading + "\n", size: headingSize, bold: true, color: ink, spacing: 4, to: result)
        append(body + "\n", size: bodySize, bold: false, color: ink, spacing: 10, to: result)
    }

    private static func append(_ text: String, size: CGFloat, bold: Bool, color: ExportColor,
                               spacing: CGFloat, to result: NSMutableAttributedString) {
        let font = bold ? ExportFont.boldSystemFont(ofSize: size) : ExportFont.systemFont(ofSize: size)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        // `.font` is the Core Text font key. Setting both crashes: a dictionary
        // literal cannot contain the same key twice.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        result.append(NSAttributedString(string: text, attributes: attributes))
    }

    // White paper. The label color would be white while the app is in dark mode
    // and the page would be blank. Speaker colors are Theme.meTint / Theme.othersTint.
    private static let ink = platformColor(red: 0, green: 0, blue: 0)
    private static let me = platformColor(red: 0.40, green: 0.55, blue: 1)
    private static let others = platformColor(red: 0.25, green: 0.82, blue: 0.62)

    private static func platformColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> ExportColor {
        #if os(macOS)
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
        UIColor(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    // MARK: Word

    // 0.40, 0.55, 1.00 and 0.25, 0.82, 0.62 — Theme.meTint and Theme.othersTint
    // as sRGB hex. Word colors a run with a hex, not a SwiftUI color.
    private static let meHex = "668CFF"
    private static let othersHex = "40D19E"

    private static func documentXML(_ document: ExportDocument) -> String {
        var paragraphs: [String] = []
        paragraphs.append(paragraph("Title", [(document.title, nil, true)]))
        if !document.notes.isEmpty {
            paragraphs.append(paragraph("Heading", [(L("Notes"), nil, true)]))
            paragraphs.append(paragraph("Body", [(document.notes, nil, false)]))
        }
        if !document.summary.isEmpty {
            paragraphs.append(paragraph("Heading", [(L("Summary"), nil, true)]))
            paragraphs.append(paragraph("Body", [(document.summary, nil, false)]))
        }
        if !document.lines.isEmpty {
            paragraphs.append(paragraph("Heading", [(L("Transcript"), nil, true)]))
            for line in document.lines {
                let color = line.isMe ? meHex : othersHex
                paragraphs.append(paragraph("Body", [
                    (Transcriber.timestamp(line.startMs) + " ", nil, false),
                    (line.speaker, color, true),
                    (" " + line.text, nil, false),
                ]))
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            \(paragraphs.joined(separator: "\n    "))
            <w:sectPr>
              <w:pgSz w:w="12240" w:h="15840"/>
              <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """
    }

    /// One paragraph. `runs` are (text, hex color or nil, bold).
    private static func paragraph(_ style: String, _ runs: [(String, String?, Bool)]) -> String {
        let body = runs.map { text, color, bold -> String in
            var props: [String] = []
            if bold { props.append("<w:b/>") }
            if let color { props.append("<w:color w:val=\"\(color)\"/>") }
            let properties = props.isEmpty ? "" : "<w:rPr>\(props.joined())</w:rPr>"
            return "<w:r>\(properties)<w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r>"
        }.joined()
        return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(body)</w:p>"
    }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // Word stores a size in half-points. 40/30/26 are the printed 20/15/13,
    // the same steps as the PDF, not on-screen type.
    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:styleId="Title">
        <w:name w:val="Title"/>
        <w:rPr><w:b/><w:sz w:val="40"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading">
        <w:name w:val="heading 1"/>
        <w:rPr><w:b/><w:sz w:val="30"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Body" w:default="1">
        <w:name w:val="Body"/>
        <w:rPr><w:sz w:val="26"/></w:rPr>
      </w:style>
    </w:styles>
    """

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    </Types>
    """

    private static let packageRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """
}

/// A zip of stored (uncompressed) entries. Enough for a `.docx`, which is a zip,
/// and for `unzip -t` to accept it. No compression, so there is nothing to link.
enum ZipStore {
    struct Entry {
        var name: String
        var data: Data
    }

    static func archive(_ entries: [Entry]) -> Data {
        var local = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt32(local.count)
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            local.append(localHeader(name: name, crc: crc, size: size))
            local.append(entry.data)
            central.append(centralHeader(name: name, crc: crc, size: size, offset: offset))
        }
        var archive = local
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(endOfCentralDirectory(count: UInt16(entries.count),
                                              size: UInt32(central.count),
                                              offset: centralOffset))
        return archive
    }

    private static let version: UInt16 = 20
    private static let utf8Flag: UInt16 = 1 << 11
    /// 2026-11-22 12:00, so a reader is not handed a zero date.
    private static let dosTime: UInt16 = 12 << 11
    private static let dosDate: UInt16 = 22 | (11 << 5) | (46 << 9)

    private static func localHeader(name: Data, crc: UInt32, size: UInt32) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x04034b50))
        data.appendLE(version)
        data.appendLE(utf8Flag)
        data.appendLE(UInt16(0))
        data.appendLE(dosTime)
        data.appendLE(dosDate)
        data.appendLE(crc)
        data.appendLE(size)
        data.appendLE(size)
        data.appendLE(UInt16(name.count))
        data.appendLE(UInt16(0))
        data.append(name)
        return data
    }

    private static func centralHeader(name: Data, crc: UInt32, size: UInt32, offset: UInt32) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x02014b50))
        data.appendLE(UInt16(0x0314))
        data.appendLE(version)
        data.appendLE(utf8Flag)
        data.appendLE(UInt16(0))
        data.appendLE(dosTime)
        data.appendLE(dosDate)
        data.appendLE(crc)
        data.appendLE(size)
        data.appendLE(size)
        data.appendLE(UInt16(name.count))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt32(0))
        data.appendLE(offset)
        data.append(name)
        return data
    }

    private static func endOfCentralDirectory(count: UInt16, size: UInt32, offset: UInt32) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x06054b50))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(count)
        data.appendLE(count)
        data.appendLE(size)
        data.appendLE(offset)
        data.appendLE(UInt16(0))
        return data
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
