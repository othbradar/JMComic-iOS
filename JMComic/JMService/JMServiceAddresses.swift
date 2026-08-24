import Foundation

/// JM 服务地址的唯一内置来源。
///
/// 上游改域名、线路镜像或 HeaderVer 默认值时，只需更新本文件。
/// 用户选择及动态发现到的线路仍由 `AppConfiguration` 持久化，
/// 不会因内置表更新而覆盖用户当前可用的顺序。
enum JMServiceAddresses {
    static let encryptedUpstreamURL = URL(
        string: "https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt"
    )!

    static let lineConfigurationMirrorURLs: [URL] = [
        "https://app.jpacg.cc/JMComic/config.txt",
        "https://app2.jpacg.cc/JMComic/config.txt",
        "https://app3.jpacg.cc/JMComic/config.txt"
    ].compactMap(URL.init)

    static let builtInAPIDomains = [
        "https://www.cdnhjk.net",
        "https://www.cdngwc.cc",
        "https://www.cdngwc.net",
        "https://www.cdngwc.club"
    ]

    static let builtInImageDomains = [
        "https://cdn-msp.jmapiproxy1.cc",
        "https://cdn-msp.jmapiproxy3.cc",
        "https://cdn-msp.jmapinodeudzn.net",
        "https://cdn-msp.jmdanjonproxy.xyz"
    ]

    /// `config.txt` 中 `HeaderVer` 不可用时的内置值。
    static let defaultClientVersion = "2.0.26"
    static let availableImageShunts = Array(1...4)
}
