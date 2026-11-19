// Writes the Sparkle appcast for one release: the feed the published app
// reads once a day from
//   https://github.com/<repo>/releases/latest/download/appcast.xml
// It holds one item, the newest release, with the EdDSA signature that
// scripts/release.sh got from Sparkle's sign_update for the notarized,
// stapled DMG. Release notes are markdown (Sparkle 2.9+ shows them as such).
//
// scripts/release.sh runs it; to run it by hand (for example to point a test
// feed at a DMG served from this Mac):
//   swift scripts/sparkle/make-appcast.swift \
//     --version 1.0 --build 1 \
//     --download-url https://github.com/eshan-chawla/elfhub-mac/releases/download/v1.0/elfhub.dmg \
//     --ed-signature <from sign_update -p> --length <DMG size in bytes> \
//     --minimum-system-version 14.2.0 --notes-file notes.md --output appcast.xml

import Foundation

let usage = """
usage: make-appcast.swift --version <1.0> --build <1> --download-url <url> \
--ed-signature <base64> --length <bytes> --minimum-system-version <14.2.0> \
--notes-file <notes.md> --output <appcast.xml>
"""

func failAndExit(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-appcast: \(message)\n\(usage)\n".utf8))
    exit(1)
}

// "--name value" pairs into a dictionary.
var argumentValuesByName: [String: String] = [:]
var remainingArguments = Array(CommandLine.arguments.dropFirst())
while !remainingArguments.isEmpty {
    let argumentName = remainingArguments.removeFirst()
    guard argumentName.hasPrefix("--"), !remainingArguments.isEmpty else {
        failAndExit("expected --name value pairs, got \(argumentName)")
    }
    argumentValuesByName[String(argumentName.dropFirst(2))] = remainingArguments.removeFirst()
}

func requiredArgument(_ argumentName: String) -> String {
    guard let argumentValue = argumentValuesByName[argumentName], !argumentValue.isEmpty else {
        failAndExit("missing --\(argumentName)")
    }
    return argumentValue
}

let shortVersion = requiredArgument("version")
let buildNumber = requiredArgument("build")
let downloadURLString = requiredArgument("download-url")
let edSignature = requiredArgument("ed-signature")
let lengthInBytes = requiredArgument("length")
let minimumSystemVersion = requiredArgument("minimum-system-version")
let notesFilePath = requiredArgument("notes-file")
let outputFilePath = requiredArgument("output")

guard Int(buildNumber) != nil else { failAndExit("--build must be a whole number (Sparkle compares it)") }
guard Int(lengthInBytes).map({ $0 > 0 }) == true else { failAndExit("--length must be a positive number of bytes") }
guard let downloadURL = URL(string: downloadURLString), let scheme = downloadURL.scheme, ["https", "http"].contains(scheme) else {
    failAndExit("--download-url must be an http(s) URL")
}
guard Data(base64Encoded: edSignature)?.count == 64 else { failAndExit("--ed-signature isn't an EdDSA signature") }
guard let releaseNotesMarkdown = try? String(contentsOfFile: notesFilePath, encoding: .utf8) else {
    failAndExit("can't read --notes-file \(notesFilePath)")
}

func escapedForXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// CDATA can't contain "]]>", so that sequence is split across two sections.
func wrappedInCDATA(_ text: String) -> String {
    "<![CDATA[" + text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
}

let publicationDateFormatter = DateFormatter()
publicationDateFormatter.locale = Locale(identifier: "en_US_POSIX")
publicationDateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
publicationDateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

let appcastXML = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>elfhub</title>
        <item>
            <title>Version \(escapedForXML(shortVersion))</title>
            <pubDate>\(publicationDateFormatter.string(from: Date()))</pubDate>
            <sparkle:version>\(escapedForXML(buildNumber))</sparkle:version>
            <sparkle:shortVersionString>\(escapedForXML(shortVersion))</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>\(escapedForXML(minimumSystemVersion))</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <description sparkle:format="markdown">\(wrappedInCDATA(releaseNotesMarkdown))</description>
            <enclosure url="\(escapedForXML(downloadURLString))" length="\(escapedForXML(lengthInBytes))" type="application/octet-stream" sparkle:edSignature="\(escapedForXML(edSignature))"/>
        </item>
    </channel>
</rss>

"""

do {
    try Data(appcastXML.utf8).write(to: URL(fileURLWithPath: outputFilePath), options: .atomic)
    print("Wrote \(outputFilePath)")
} catch {
    failAndExit("can't write \(outputFilePath): \(error.localizedDescription)")
}
