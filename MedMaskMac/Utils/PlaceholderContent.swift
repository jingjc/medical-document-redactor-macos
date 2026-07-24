import Foundation

enum PlaceholderContent {
    static let files: [FileItem] = [
        FileItem(
            displayName: "Ward_Admission_Report.pdf",
            kind: .pdf,
            status: .readyForReview,
            pages: [
                PageItem(
                    pageNumber: 1,
                    status: .readyForReview,
                    sensitiveRegions: [
                        SensitiveRegion(
                            kind: .name,
                            bounds: NormalizedRect(x: 0.08, y: 0.10, width: 0.28, height: 0.05)
                        ),
                        SensitiveRegion(
                            kind: .chineseIDNumber,
                            bounds: NormalizedRect(x: 0.11, y: 0.23, width: 0.34, height: 0.05)
                        )
                    ]
                ),
                PageItem(
                    pageNumber: 2,
                    status: .pendingDetection,
                    sensitiveRegions: [
                        SensitiveRegion(
                            kind: .barcode,
                            bounds: NormalizedRect(x: 0.74, y: 0.08, width: 0.16, height: 0.12)
                        )
                    ]
                )
            ]
        ),
        FileItem(
            displayName: "Lab_Slip_0426.png",
            kind: .image,
            status: .needsAttention,
            pages: [
                PageItem(
                    pageNumber: 1,
                    status: .pendingDetection,
                    sensitiveRegions: [
                        SensitiveRegion(
                            kind: .phoneNumber,
                            bounds: NormalizedRect(x: 0.14, y: 0.71, width: 0.24, height: 0.05)
                        )
                    ]
                )
            ]
        )
    ]
}
