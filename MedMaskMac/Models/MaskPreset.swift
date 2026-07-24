import Foundation

enum MaskPreset: String, CaseIterable, Identifiable {
    case standard
    case strict
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .standard:
            L10n.Preset.standardTitle
        case .strict:
            L10n.Preset.strictTitle
        case .custom:
            L10n.Preset.customTitle
        }
    }

    var summary: String {
        switch self {
        case .standard:
            L10n.Preset.standardSummary
        case .strict:
            L10n.Preset.strictSummary
        case .custom:
            L10n.Preset.customSummary
        }
    }
}

enum MaskCustomField: String, CaseIterable, Identifiable, Hashable {
    case name
    case phone
    case idNumber
    case medicalNumbers
    case sex
    case age
    case dates
    case address
    case email
    case hospitalDepartment
    case doctor
    case staffSignature

    var id: Self { self }

    var title: String {
        switch self {
        case .name:
            L10n.CustomField.name
        case .phone:
            L10n.CustomField.phone
        case .idNumber:
            L10n.CustomField.idNumber
        case .medicalNumbers:
            L10n.CustomField.medicalNumbers
        case .sex:
            L10n.CustomField.sex
        case .age:
            L10n.CustomField.age
        case .dates:
            L10n.CustomField.dates
        case .address:
            L10n.CustomField.address
        case .email:
            L10n.CustomField.email
        case .hospitalDepartment:
            L10n.CustomField.hospitalDepartment
        case .doctor:
            L10n.CustomField.doctor
        case .staffSignature:
            L10n.CustomField.staffSignature
        }
    }

    var includedOCRCategories: Set<OCRCandidateCategory> {
        switch self {
        case .name:
            [.name]
        case .phone:
            [.phone]
        case .idNumber:
            [.chineseID, .documentNumber]
        case .medicalNumbers:
            [.medicalNumber]
        case .sex:
            [.sex]
        case .age:
            [.age]
        case .dates:
            [.date, .birthday, .examDate]
        case .address:
            [.address]
        case .email:
            [.email]
        case .hospitalDepartment:
            [.hospital, .department]
        case .doctor:
            [.doctor]
        case .staffSignature:
            [.staffSignature]
        }
    }

    static let defaultEnabledFields: Set<MaskCustomField> = [
        .name,
        .phone,
        .idNumber,
        .medicalNumbers
    ]
}

struct OCRDetectionOptions: Equatable {
    var preset: MaskPreset
    var customFields: Set<MaskCustomField>

    var includedCategories: Set<OCRCandidateCategory> {
        switch preset {
        case .standard:
            Self.standardCategories
        case .strict:
            Self.strictCategories
        case .custom:
            customFields.reduce(into: Set<OCRCandidateCategory>()) { categories, field in
                categories.formUnion(field.includedOCRCategories)
            }
        }
    }

    static let standardCategories: Set<OCRCandidateCategory> = [
        .name,
        .phone,
        .chineseID,
        .documentNumber,
        .medicalNumber
    ]

    static let strictCategories: Set<OCRCandidateCategory> = standardCategories.union([
        .sex,
        .age,
        .birthday,
        .examDate,
        .date,
        .address,
        .email,
        .fax,
        .hospital,
        .department,
        .doctor,
        .staffSignature,
        .bedNumber
    ])
}
