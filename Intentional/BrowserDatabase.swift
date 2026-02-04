import Foundation
import Cocoa

// MARK: - Browser Type Enums

enum BrowserEngine {
    case chromium
    case gecko
    case webkit
    case goanna
    case other
}

enum NativeMessagingType {
    case chromium  // Uses Chrome Native Messaging protocol
    case mozilla   // Uses Mozilla Native Messaging protocol
    case safari    // Uses Safari App Extensions
    case none
}

// MARK: - Browser Info Structure

struct BrowserInfo {
    let bundleId: String
    let name: String
    let engine: BrowserEngine

    // Path discovery hints (not hardcoded paths!)
    let dataFolderName: String           // e.g., "Google/Chrome"
    let companyName: String              // e.g., "Google"
    let alternativeDataFolders: [String] // Alternative possible folder names

    // Capabilities
    let supportsAppleScript: Bool
    let supportsWebExtensions: Bool
    let supportsNativeMessaging: Bool
    let nativeMessagingType: NativeMessagingType

    // Extension page URL
    var extensionPageUrl: String {
        switch engine {
        case .chromium:
            return "chrome://extensions/"
        case .gecko:
            return "about:addons"
        case .webkit where bundleId.contains("safari"):
            return "safari://extensions/"
        default:
            return "chrome://extensions/"
        }
    }
}

// MARK: - Browser Database

struct BrowserDatabase {

    // Browsers ordered by usage/popularity (most common first for faster discovery)
    static let allBrowsers: [BrowserInfo] = [
        // MARK: - Top 10 Most Popular Browsers (checked first)

        BrowserInfo(
            bundleId: "com.google.Chrome",
            name: "Google Chrome",
            engine: .chromium,
            dataFolderName: "Google/Chrome",
            companyName: "Google",
            alternativeDataFolders: ["Chrome"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.google.Chrome.beta",
            name: "Chrome Beta",
            engine: .chromium,
            dataFolderName: "Google/Chrome Beta",
            companyName: "Google",
            alternativeDataFolders: ["Chrome Beta"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.google.Chrome.dev",
            name: "Chrome Dev",
            engine: .chromium,
            dataFolderName: "Google/Chrome Dev",
            companyName: "Google",
            alternativeDataFolders: ["Chrome Dev"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.google.Chrome.canary",
            name: "Chrome Canary",
            engine: .chromium,
            dataFolderName: "Google/Chrome Canary",
            companyName: "Google",
            alternativeDataFolders: ["Chrome Canary"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.microsoft.edgemac",
            name: "Microsoft Edge",
            engine: .chromium,
            dataFolderName: "Microsoft Edge",
            companyName: "Microsoft",
            alternativeDataFolders: ["Edge"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.microsoft.edgemac.Beta",
            name: "Edge Beta",
            engine: .chromium,
            dataFolderName: "Microsoft Edge Beta",
            companyName: "Microsoft",
            alternativeDataFolders: ["Edge Beta"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.microsoft.edgemac.Dev",
            name: "Edge Dev",
            engine: .chromium,
            dataFolderName: "Microsoft Edge Dev",
            companyName: "Microsoft",
            alternativeDataFolders: ["Edge Dev"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.microsoft.edgemac.Canary",
            name: "Edge Canary",
            engine: .chromium,
            dataFolderName: "Microsoft Edge Canary",
            companyName: "Microsoft",
            alternativeDataFolders: ["Edge Canary"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.brave.Browser",
            name: "Brave",
            engine: .chromium,
            dataFolderName: "BraveSoftware/Brave-Browser",
            companyName: "BraveSoftware",
            alternativeDataFolders: ["Brave", "Brave Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.brave.Browser.beta",
            name: "Brave Beta",
            engine: .chromium,
            dataFolderName: "BraveSoftware/Brave-Browser-Beta",
            companyName: "BraveSoftware",
            alternativeDataFolders: ["Brave Beta"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.brave.Browser.nightly",
            name: "Brave Nightly",
            engine: .chromium,
            dataFolderName: "BraveSoftware/Brave-Browser-Nightly",
            companyName: "BraveSoftware",
            alternativeDataFolders: ["Brave Nightly"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "company.thebrowser.Browser",
            name: "Arc",
            engine: .chromium,
            dataFolderName: "Arc/User Data",
            companyName: "",
            alternativeDataFolders: ["Arc", "Arc Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.vivaldi.Vivaldi",
            name: "Vivaldi",
            engine: .chromium,
            dataFolderName: "Vivaldi",
            companyName: "",
            alternativeDataFolders: ["Vivaldi Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.operasoftware.Opera",
            name: "Opera",
            engine: .chromium,
            dataFolderName: "com.operasoftware.Opera",
            companyName: "Opera",
            alternativeDataFolders: ["Opera"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.operasoftware.OperaGX",
            name: "Opera GX",
            engine: .chromium,
            dataFolderName: "com.operasoftware.OperaGX",
            companyName: "Opera",
            alternativeDataFolders: ["Opera GX"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "org.chromium.Chromium",
            name: "Chromium",
            engine: .chromium,
            dataFolderName: "Chromium",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "io.github.ungoogled_software.ungoogled_chromium",
            name: "Ungoogled Chromium",
            engine: .chromium,
            dataFolderName: "Chromium",
            companyName: "",
            alternativeDataFolders: ["Ungoogled Chromium"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "ru.yandex.desktop.yandex-browser",
            name: "Yandex Browser",
            engine: .chromium,
            dataFolderName: "Yandex/YandexBrowser",
            companyName: "Yandex",
            alternativeDataFolders: ["Yandex Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Productivity Chromium Browsers

        BrowserInfo(
            bundleId: "com.sigmaos.sigmaos",
            name: "SigmaOS",
            engine: .chromium,
            dataFolderName: "SigmaOS",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.pushplaylabs.sidekick",
            name: "Sidekick",
            engine: .chromium,
            dataFolderName: "Sidekick",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.tryshift.shift",
            name: "Shift",
            engine: .chromium,
            dataFolderName: "Shift",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "io.wavebox.wavebox",
            name: "Wavebox",
            engine: .chromium,
            dataFolderName: "WaveboxApp",
            companyName: "",
            alternativeDataFolders: ["Wavebox"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Privacy Chromium Browsers

        BrowserInfo(
            bundleId: "de.iridiumbrowser",
            name: "Iridium",
            engine: .chromium,
            dataFolderName: "Iridium",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.hiddenreflex.epic",
            name: "Epic Privacy Browser",
            engine: .chromium,
            dataFolderName: "Epic",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "de.srware.iron",
            name: "SRWare Iron",
            engine: .chromium,
            dataFolderName: "Iron",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.ur.browser",
            name: "UR Browser",
            engine: .chromium,
            dataFolderName: "UR Browser",
            companyName: "",
            alternativeDataFolders: ["UR"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Regional Chromium Browsers

        BrowserInfo(
            bundleId: "com.flashpeak.slimjet",
            name: "Slimjet",
            engine: .chromium,
            dataFolderName: "Slimjet",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.coccoc.browser",
            name: "CocCoc",
            engine: .chromium,
            dataFolderName: "Coccoc",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.naver.whale",
            name: "Whale Browser",
            engine: .chromium,
            dataFolderName: "Naver/Whale",
            companyName: "Naver",
            alternativeDataFolders: ["Whale"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "jp.co.fenrir.sleipnir",
            name: "Sleipnir",
            engine: .chromium,
            dataFolderName: "Sleipnir",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.duckduckgo.macos.browser",
            name: "DuckDuckGo",
            engine: .webkit,
            dataFolderName: "DuckDuckGo",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Firefox/Gecko Browsers

        BrowserInfo(
            bundleId: "org.mozilla.firefox",
            name: "Firefox",
            engine: .gecko,
            dataFolderName: "Firefox",
            companyName: "Mozilla",
            alternativeDataFolders: ["Mozilla/Firefox"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "org.mozilla.firefoxdeveloperedition",
            name: "Firefox Developer Edition",
            engine: .gecko,
            dataFolderName: "Firefox",
            companyName: "Mozilla",
            alternativeDataFolders: ["Mozilla/Firefox"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "org.mozilla.nightly",
            name: "Firefox Nightly",
            engine: .gecko,
            dataFolderName: "Firefox",
            companyName: "Mozilla",
            alternativeDataFolders: ["Mozilla/Firefox"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "org.mozilla.firefoxesr",
            name: "Firefox ESR",
            engine: .gecko,
            dataFolderName: "Firefox",
            companyName: "Mozilla",
            alternativeDataFolders: ["Mozilla/Firefox"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "org.torproject.torbrowser",
            name: "Tor Browser",
            engine: .gecko,
            dataFolderName: "TorBrowser-Data",
            companyName: "",
            alternativeDataFolders: ["Tor Browser"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "net.mullvad.browser",
            name: "Mullvad Browser",
            engine: .gecko,
            dataFolderName: "Mullvad Browser",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "io.gitlab.librewolf-community",
            name: "LibreWolf",
            engine: .gecko,
            dataFolderName: "librewolf",
            companyName: "",
            alternativeDataFolders: ["LibreWolf"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "net.waterfox.waterfox",
            name: "Waterfox",
            engine: .gecko,
            dataFolderName: "Waterfox",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "net.waterfox.waterfoxclassic",
            name: "Waterfox Classic",
            engine: .gecko,
            dataFolderName: "Waterfox Classic",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "io.github.zen-browser.zen",
            name: "Zen Browser",
            engine: .gecko,
            dataFolderName: "zen",
            companyName: "",
            alternativeDataFolders: ["Zen"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "one.ablaze.floorp",
            name: "Floorp",
            engine: .gecko,
            dataFolderName: "Floorp",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "org.mozilla.seamonkey",
            name: "SeaMonkey",
            engine: .gecko,
            dataFolderName: "SeaMonkey",
            companyName: "Mozilla",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Goanna (Gecko fork)

        BrowserInfo(
            bundleId: "org.palemoon.browser",
            name: "Pale Moon",
            engine: .goanna,
            dataFolderName: "Pale Moon",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "net.palemoon.navigator",
            name: "Pale Moon",
            engine: .goanna,
            dataFolderName: "Pale Moon",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.mozilla.basilisk",
            name: "Basilisk",
            engine: .goanna,
            dataFolderName: "Basilisk",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Safari/WebKit

        BrowserInfo(
            bundleId: "com.apple.Safari",
            name: "Safari",
            engine: .webkit,
            dataFolderName: "Safari",
            companyName: "Apple",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .safari
        ),

        BrowserInfo(
            bundleId: "com.apple.SafariTechnologyPreview",
            name: "Safari Technology Preview",
            engine: .webkit,
            dataFolderName: "Safari Technology Preview",
            companyName: "Apple",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .safari
        ),

        BrowserInfo(
            bundleId: "com.kagi.kagimacOS",
            name: "Orion",
            engine: .webkit,
            dataFolderName: "Orion",
            companyName: "Kagi",
            alternativeDataFolders: ["Orion Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Other Browsers

        BrowserInfo(
            bundleId: "org.qutebrowser.qutebrowser",
            name: "qutebrowser",
            engine: .other,
            dataFolderName: "qutebrowser",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "jp.lunascape.Lunascape",
            name: "Lunascape",
            engine: .other,
            dataFolderName: "Lunascape",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.maxthon.mac",
            name: "Maxthon",
            engine: .other,
            dataFolderName: "Maxthon",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Additional Opera Variants

        BrowserInfo(
            bundleId: "com.operasoftware.OperaDeveloper",
            name: "Opera Developer",
            engine: .chromium,
            dataFolderName: "com.operasoftware.OperaDeveloper",
            companyName: "Opera",
            alternativeDataFolders: ["Opera Developer"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.operasoftware.OperaBeta",
            name: "Opera Beta",
            engine: .chromium,
            dataFolderName: "com.operasoftware.OperaBeta",
            companyName: "Opera",
            alternativeDataFolders: ["Opera Beta"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.operasoftware.OperaNext",
            name: "Opera Next",
            engine: .chromium,
            dataFolderName: "com.operasoftware.OperaNext",
            companyName: "Opera",
            alternativeDataFolders: ["Opera Next"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Security-Focused Chromium Browsers

        BrowserInfo(
            bundleId: "com.comodo.Dragon",
            name: "Comodo Dragon",
            engine: .chromium,
            dataFolderName: "Comodo/Dragon",
            companyName: "Comodo",
            alternativeDataFolders: ["Dragon"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.avast.browser",
            name: "Avast Secure Browser",
            engine: .chromium,
            dataFolderName: "AVAST Software/Browser",
            companyName: "AVAST Software",
            alternativeDataFolders: ["Avast", "Avast Secure Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.avg.browser",
            name: "AVG Secure Browser",
            engine: .chromium,
            dataFolderName: "AVG/Browser",
            companyName: "AVG",
            alternativeDataFolders: ["AVG", "AVG Secure Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Developer-Focused Chromium Browsers

        BrowserInfo(
            bundleId: "com.centbrowser.CentBrowser",
            name: "Cent Browser",
            engine: .chromium,
            dataFolderName: "CentBrowser",
            companyName: "",
            alternativeDataFolders: ["Cent"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.citrio.browser",
            name: "Citrio",
            engine: .chromium,
            dataFolderName: "Citrio",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.colibri.ColibriApp",
            name: "Colibri",
            engine: .chromium,
            dataFolderName: "Colibri",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.blisk.Blisk",
            name: "Blisk",
            engine: .chromium,
            dataFolderName: "Blisk",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.firstversionist.polypane",
            name: "Polypane",
            engine: .chromium,
            dataFolderName: "Polypane",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.manojvivek.responsively-app",
            name: "Sizzy",
            engine: .chromium,
            dataFolderName: "Sizzy",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "app.responsively.app",
            name: "Responsively",
            engine: .chromium,
            dataFolderName: "Responsively",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Experimental Chromium Browsers

        BrowserInfo(
            bundleId: "com.beakerbrowser.beaker",
            name: "Beaker",
            engine: .chromium,
            dataFolderName: "Beaker Browser",
            companyName: "",
            alternativeDataFolders: ["Beaker"],
            supportsAppleScript: true,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Minimalist Chromium/Other Browsers

        BrowserInfo(
            bundleId: "com.minbrowser.min",
            name: "Min Browser",
            engine: .chromium,
            dataFolderName: "Min",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.kde.falkon",
            name: "Falkon",
            engine: .other,
            dataFolderName: "falkon",
            companyName: "",
            alternativeDataFolders: ["Falkon"],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.gnome.Epiphany",
            name: "GNOME Web",
            engine: .webkit,
            dataFolderName: "Epiphany",
            companyName: "",
            alternativeDataFolders: ["GNOME Web"],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.kde.konqueror",
            name: "Konqueror",
            engine: .other,
            dataFolderName: "konqueror",
            companyName: "",
            alternativeDataFolders: ["Konqueror"],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.kmeleon.browser",
            name: "K-Meleon",
            engine: .gecko,
            dataFolderName: "K-Meleon",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.otter-browser",
            name: "Otter Browser",
            engine: .other,
            dataFolderName: "Otter",
            companyName: "",
            alternativeDataFolders: ["Otter Browser"],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.midori-browser.midori",
            name: "Midori",
            engine: .webkit,
            dataFolderName: "Midori",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Next-Generation Browsers

        BrowserInfo(
            bundleId: "org.ladybird-browser.ladybird",
            name: "Ladybird",
            engine: .other,
            dataFolderName: "Ladybird",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.nyxt.browser",
            name: "Nyxt",
            engine: .other,
            dataFolderName: "nyxt",
            companyName: "",
            alternativeDataFolders: ["Nyxt"],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.servo.servo",
            name: "Servo",
            engine: .other,
            dataFolderName: "Servo",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.ekioh.flow",
            name: "Flow",
            engine: .other,
            dataFolderName: "Flow",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Text-Only Browsers

        BrowserInfo(
            bundleId: "org.netsurf-browser.netsurf",
            name: "NetSurf",
            engine: .other,
            dataFolderName: "NetSurf",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.dillo.browser",
            name: "Dillo",
            engine: .other,
            dataFolderName: "dillo",
            companyName: "",
            alternativeDataFolders: ["Dillo"],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Legacy Mac Browsers

        BrowserInfo(
            bundleId: "org.caminobrowser.Camino",
            name: "Camino",
            engine: .gecko,
            dataFolderName: "Camino",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.omnigroup.OmniWeb5",
            name: "OmniWeb",
            engine: .webkit,
            dataFolderName: "OmniWeb",
            companyName: "Omni Group",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "de.icab.iCab",
            name: "iCab",
            engine: .webkit,
            dataFolderName: "iCab",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "jp.hmdt.shiira",
            name: "Shiira",
            engine: .webkit,
            dataFolderName: "Shiira",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.sonsofthunder.Sunrise",
            name: "Sunrise",
            engine: .webkit,
            dataFolderName: "Sunrise",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.runecats.Roccat",
            name: "Roccat",
            engine: .webkit,
            dataFolderName: "Roccat",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.cruzapp.Cruz",
            name: "Cruz",
            engine: .webkit,
            dataFolderName: "Cruz",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.mesadynamics.Stainless",
            name: "Stainless",
            engine: .webkit,
            dataFolderName: "Stainless",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Site-Specific Browsers (SSB)

        BrowserInfo(
            bundleId: "com.fluidapp.Fluid",
            name: "Fluid",
            engine: .webkit,
            dataFolderName: "Fluid",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.BbrowserCompany.Coherence",
            name: "Coherence",
            engine: .webkit,
            dataFolderName: "Coherence",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "org.mozilla.prism",
            name: "Prism",
            engine: .gecko,
            dataFolderName: "Prism",
            companyName: "Mozilla",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Additional Firefox Variants

        BrowserInfo(
            bundleId: "com.comodo.IceDragon",
            name: "Comodo IceDragon",
            engine: .gecko,
            dataFolderName: "Comodo/IceDragon",
            companyName: "Comodo",
            alternativeDataFolders: ["IceDragon"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "com.ghostery.midnight",
            name: "Ghostery Midnight",
            engine: .gecko,
            dataFolderName: "Ghostery",
            companyName: "Ghostery",
            alternativeDataFolders: ["Ghostery Midnight"],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        BrowserInfo(
            bundleId: "org.cliqz.browser",
            name: "Cliqz",
            engine: .gecko,
            dataFolderName: "Cliqz",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .mozilla
        ),

        // MARK: - Regional Browsers (Asia-Pacific)

        BrowserInfo(
            bundleId: "com.tencent.QQBrowser",
            name: "QQ Browser",
            engine: .chromium,
            dataFolderName: "QQBrowser",
            companyName: "Tencent",
            alternativeDataFolders: ["QQ Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.ucweb.mac",
            name: "UC Browser",
            engine: .chromium,
            dataFolderName: "UCBrowser",
            companyName: "UCWeb",
            alternativeDataFolders: ["UC Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.baidu.spark",
            name: "Baidu Spark",
            engine: .chromium,
            dataFolderName: "BaiduSpark",
            companyName: "Baidu",
            alternativeDataFolders: ["Spark"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.qihoo.360se",
            name: "360 Secure Browser",
            engine: .chromium,
            dataFolderName: "360se",
            companyName: "Qihoo",
            alternativeDataFolders: ["360 Secure Browser"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.sogou.SogouExplorer",
            name: "Sogou Browser",
            engine: .chromium,
            dataFolderName: "Sogou/SogouExplorer",
            companyName: "Sogou",
            alternativeDataFolders: ["Sogou"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.maxthon.mx5",
            name: "Maxthon 5",
            engine: .chromium,
            dataFolderName: "Maxthon5",
            companyName: "Maxthon",
            alternativeDataFolders: ["Maxthon 5"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.maxthon.mx6",
            name: "Maxthon 6",
            engine: .chromium,
            dataFolderName: "Maxthon6",
            companyName: "Maxthon",
            alternativeDataFolders: ["Maxthon 6"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.liebao.browser",
            name: "Liebao Browser",
            engine: .chromium,
            dataFolderName: "Liebao",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Regional Browsers (Eastern Europe/Russia)

        BrowserInfo(
            bundleId: "ru.yandex.desktop.yandex-browser-beta",
            name: "Yandex Browser Beta",
            engine: .chromium,
            dataFolderName: "Yandex/YandexBrowser-Beta",
            companyName: "Yandex",
            alternativeDataFolders: ["Yandex Browser Beta"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.mail.ru.atom",
            name: "Atom Browser",
            engine: .chromium,
            dataFolderName: "Atom",
            companyName: "Mail.Ru",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.orbitum.browser",
            name: "Orbitum",
            engine: .chromium,
            dataFolderName: "Orbitum",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.amigo.browser",
            name: "Amigo",
            engine: .chromium,
            dataFolderName: "Amigo",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Gaming/Social Browsers

        BrowserInfo(
            bundleId: "gg.discord.browser",
            name: "Discord Browser",
            engine: .chromium,
            dataFolderName: "discord",
            companyName: "Discord",
            alternativeDataFolders: ["Discord"],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        BrowserInfo(
            bundleId: "com.overwolf.browser",
            name: "Overwolf Browser",
            engine: .chromium,
            dataFolderName: "Overwolf",
            companyName: "Overwolf",
            alternativeDataFolders: [],
            supportsAppleScript: false,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),

        // MARK: - Enterprise Browsers

        BrowserInfo(
            bundleId: "com.island.browser",
            name: "Island Browser",
            engine: .chromium,
            dataFolderName: "Island",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.talon.browser",
            name: "Talon",
            engine: .chromium,
            dataFolderName: "Talon",
            companyName: "",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - AI-Powered Browsers

        BrowserInfo(
            bundleId: "com.openai.atlas",
            name: "ChatGPT Atlas",
            engine: .chromium,
            dataFolderName: "ChatGPT",
            companyName: "OpenAI",
            alternativeDataFolders: ["OpenAI/ChatGPT", "Atlas"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.openai.atlas.web",
            name: "ChatGPT Atlas Web",
            engine: .chromium,
            dataFolderName: "ChatGPT",
            companyName: "OpenAI",
            alternativeDataFolders: ["OpenAI/ChatGPT", "Atlas Web"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "ai.perplexity.comet",
            name: "Perplexity Comet",
            engine: .chromium,
            dataFolderName: "Perplexity",
            companyName: "Perplexity",
            alternativeDataFolders: ["Comet", "Perplexity Comet"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        // MARK: - Niche/Specialized Browsers

        BrowserInfo(
            bundleId: "com.kagi.kagimacOS.dev",
            name: "Orion Developer",
            engine: .webkit,
            dataFolderName: "Orion Developer",
            companyName: "Kagi",
            alternativeDataFolders: ["Orion Dev"],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.kagi.kagimacOS.beta",
            name: "Orion Beta",
            engine: .webkit,
            dataFolderName: "Orion Beta",
            companyName: "Kagi",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: true,
            supportsNativeMessaging: true,
            nativeMessagingType: .chromium
        ),

        BrowserInfo(
            bundleId: "com.apple.SafariPrivateBrowsing",
            name: "Safari Private",
            engine: .webkit,
            dataFolderName: "Safari",
            companyName: "Apple",
            alternativeDataFolders: [],
            supportsAppleScript: true,
            supportsWebExtensions: false,
            supportsNativeMessaging: false,
            nativeMessagingType: .none
        ),
    ]

    // Helper to find browser by bundle ID
    static func browser(withBundleId bundleId: String) -> BrowserInfo? {
        return allBrowsers.first { $0.bundleId == bundleId }
    }

    // Get all Chromium browsers
    static var chromiumBrowsers: [BrowserInfo] {
        return allBrowsers.filter { $0.engine == .chromium }
    }

    // Get all Gecko browsers
    static var geckoBrowsers: [BrowserInfo] {
        return allBrowsers.filter { $0.engine == .gecko }
    }

    // Get all WebKit browsers
    static var webkitBrowsers: [BrowserInfo] {
        return allBrowsers.filter { $0.engine == .webkit }
    }
}
