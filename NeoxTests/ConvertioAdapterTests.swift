import Testing
import Foundation
import WebKitAgent

// MARK: - Convertio Adapter Tests

@Suite("Convertio Adapter Tests")
@MainActor
struct ConvertioAdapterTests {

    @Test("Convertio adapter is registered after loadBundledAdapters")
    func convertioRegistered() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")
        #expect(adapter != nil, "Convertio convert adapter should be registered")
    }

    @Test("Convertio adapter has correct site and name")
    func convertioProperties() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")!
        #expect(adapter.site == "convertio")
        #expect(adapter.name == "convert")
    }

    @Test("Convertio adapter requires browser")
    func convertioRequiresBrowser() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")!
        #expect(adapter.requiresBrowser)
    }

    @Test("Convertio adapter has filePath and outputFormat args")
    func convertioArgs() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")!
        let argNames = adapter.args.map(\.name)
        #expect(argNames.contains("filePath"))
        #expect(argNames.contains("outputFormat"))
    }

    @Test("Convertio adapter has description mentioning convertio")
    func convertioDescription() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let adapter = registry.find(site: "convertio", action: "convert")!
        #expect(adapter.adapterDescription.lowercased().contains("convertio"))
    }

    @Test("List formatted output includes convertio")
    func listIncludesConvertio() {
        let registry = AdapterRegistry()
        registry.loadBundledAdapters()
        let output = registry.listFormatted()
        #expect(output.contains("convertio"))
    }
}
