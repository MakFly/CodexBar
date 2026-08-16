import Foundation

extension ProviderConfig {
    public var codexActiveSource: CodexActiveSource? {
        get { self.extensionValue(forKey: "codexActiveSource") }
        set { self.setExtensionValue(newValue, forKey: "codexActiveSource") }
    }

    public var codexProfileHomePaths: [String]? {
        get { self.extensionValue(forKey: "codexProfileHomePaths") }
        set { self.setExtensionValue(newValue, forKey: "codexProfileHomePaths") }
    }

    public var codexAutoFailoverEnabled: Bool? {
        get { self.extensionValue(forKey: "codexAutoFailoverEnabled") }
        set { self.setExtensionValue(newValue, forKey: "codexAutoFailoverEnabled") }
    }

    public var codexAutoFailoverThresholdPercent: Int? {
        get { self.extensionValue(forKey: "codexAutoFailoverThresholdPercent") }
        set { self.setExtensionValue(newValue, forKey: "codexAutoFailoverThresholdPercent") }
    }
}
