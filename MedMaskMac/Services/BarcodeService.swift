import Foundation

protocol BarcodeService {
    var statusSummary: String { get }
}

struct PlaceholderBarcodeService: BarcodeService {
    let statusSummary = L10n.Services.barcodeSummary
}
