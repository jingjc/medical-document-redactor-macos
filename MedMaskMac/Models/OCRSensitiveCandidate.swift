import Foundation

enum OCRCandidateCategory: String, CaseIterable, Hashable {
    case name
    case sex
    case age
    case address
    case phone
    case email
    case fax
    case chineseID
    case documentNumber
    case medicalNumber
    case hospital
    case department
    case doctor
    case staffSignature
    case bedNumber
    case date
    case birthday
    case examDate
    case custom
    case unknown

    var displayTitle: String {
        switch self {
        case .name:
            L10n.OCRCategory.name
        case .sex:
            L10n.OCRCategory.sex
        case .age:
            L10n.OCRCategory.age
        case .address:
            L10n.OCRCategory.address
        case .phone:
            L10n.OCRCategory.phone
        case .email:
            L10n.OCRCategory.email
        case .fax:
            L10n.OCRCategory.fax
        case .chineseID:
            L10n.OCRCategory.chineseID
        case .documentNumber:
            L10n.OCRCategory.documentNumber
        case .medicalNumber:
            L10n.OCRCategory.medicalNumber
        case .hospital:
            L10n.OCRCategory.hospital
        case .department:
            L10n.OCRCategory.department
        case .doctor:
            L10n.OCRCategory.doctor
        case .staffSignature:
            L10n.OCRCategory.staffSignature
        case .bedNumber:
            L10n.OCRCategory.bedNumber
        case .date:
            L10n.OCRCategory.date
        case .birthday:
            L10n.OCRCategory.birthday
        case .examDate:
            L10n.OCRCategory.examDate
        case .custom:
            L10n.OCRCategory.custom
        case .unknown:
            L10n.OCRCategory.unknown
        }
    }

    var regionKind: SensitiveRegionKind {
        switch self {
        case .name:
            .name
        case .phone:
            .phoneNumber
        case .chineseID:
            .chineseIDNumber
        case .medicalNumber:
            .medicalNumber
        case .sex, .age, .address, .email, .fax, .documentNumber, .hospital, .department, .doctor, .staffSignature, .bedNumber, .date, .birthday, .examDate, .custom, .unknown:
            .custom
        }
    }
}

enum OCRCandidateStatus: String, CaseIterable, Hashable {
    case pending
    case masked
    case ignored

    var displayTitle: String {
        switch self {
        case .pending:
            L10n.Review.ocrCandidateStatusPending
        case .masked:
            L10n.Review.ocrCandidateStatusMasked
        case .ignored:
            L10n.Review.ocrCandidateStatusIgnored
        }
    }
}

enum OCRCandidateDetectionKind: String, CaseIterable, Hashable {
    case directValue
    case labelValue
    case labelFallback
}

enum OCRCandidateValueState: String, CaseIterable, Hashable {
    case valueRecognized
    case valueUncertain
    case unreadableContent
    case emptyField
}

struct OCRSensitiveCandidate: Identifiable, Hashable {
    let id: UUID
    let pageID: PageItem.ID
    var text: String
    var category: OCRCandidateCategory
    var valueState: OCRCandidateValueState
    var sourceLabelText: String?
    var confidence: Double?
    var boundingBox: NormalizedRect
    var labelBoundingBox: NormalizedRect?
    var detectionKind: OCRCandidateDetectionKind
    var status: OCRCandidateStatus
    var linkedRegionID: SensitiveRegion.ID?
    var orderIndex: Int

    init(
        id: UUID = UUID(),
        pageID: PageItem.ID,
        text: String,
        category: OCRCandidateCategory,
        valueState: OCRCandidateValueState? = nil,
        sourceLabelText: String? = nil,
        confidence: Double? = nil,
        boundingBox: NormalizedRect,
        labelBoundingBox: NormalizedRect? = nil,
        detectionKind: OCRCandidateDetectionKind = .directValue,
        status: OCRCandidateStatus = .pending,
        linkedRegionID: SensitiveRegion.ID? = nil,
        orderIndex: Int = .max
    ) {
        self.id = id
        self.pageID = pageID
        self.text = text
        self.category = category
        self.valueState = valueState ?? (detectionKind == .labelFallback ? .unreadableContent : .valueRecognized)
        self.sourceLabelText = sourceLabelText
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.labelBoundingBox = labelBoundingBox
        self.detectionKind = detectionKind
        self.status = status
        self.linkedRegionID = linkedRegionID
        self.orderIndex = orderIndex
    }

    var displayTitle: String {
        guard let sourceLabelText,
              !sourceLabelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return category.displayTitle
        }

        return sourceLabelText
    }

    var displayValueText: String {
        switch valueState {
        case .valueRecognized:
            text
        case .valueUncertain:
            L10n.Review.ocrUncertainValue(text)
        case .unreadableContent:
            L10n.Review.ocrUnreadableContentValue
        case .emptyField:
            L10n.Review.ocrEmptyFieldValue
        }
    }
}
