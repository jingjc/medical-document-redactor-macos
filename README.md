# MedMaskMac

MedMaskMac is an early-stage, local-first macOS app for reviewing and redacting sensitive information in medical documents before they are shared with AI tools or other people.

The project is intended for medical-document privacy workflows across regions. Detection quality may vary by language, document format, scan quality, and layout, so every result must be reviewed before sharing.

## Current Status

MedMaskMac is currently in early alpha. It is not a production-ready privacy guarantee, and OCR-based detection can miss or misclassify sensitive information.

## Key Features

- Import PDF, PNG, JPG, and JPEG files
- Detect sensitive-information candidates with on-device OCR
- Use Standard, Strict, or Custom redaction presets
- Review, redact, ignore, and locate detected candidates
- Draw, move, resize, and delete redaction boxes manually
- Undo and redo editing operations
- Preview original and redacted pages
- Export rasterized copies with opaque, burned-in masks
- Preserve original input files and avoid overwriting existing exports

Candidate detection covers fields such as:

- Names
- Phone numbers
- Structured identity numbers
- Medical record, admission, and sample numbers
- Dates
- Healthcare organizations and departments
- Email addresses
- Staff and signature fields in Strict mode

## Privacy Model

- Document processing stays on the user's Mac
- OCR runs on-device with Apple-native frameworks
- No cloud OCR or document upload
- No accounts or cloud synchronization
- No telemetry or analytics
- No persistence of document contents between sessions
- Original input files are never modified
- Exported copies use rasterized pages and opaque masks rather than removable PDF annotations

Automatic redaction is not infallible. Users must inspect every exported page before sharing it.

## Repository Safety

- Real personal, medical, financial, or identity data must never be committed
- Test fixtures must be synthetic or fully redacted
- `PrivateFixtures/` is ignored and must remain local
- Debug-only OCR regression checks use synthetic samples
- Real documents must not be posted in issues, pull requests, screenshots, or vulnerability reports

## Build

Requirements:

- macOS 15.7 or later
- Xcode 26.3

Build from the command line:

```bash
xcodebuild -project MedMaskMac.xcodeproj -scheme MedMaskMac -configuration Debug build
```

## Security Reports

Use the repository's **Security** tab and select **Report a vulnerability** to submit security or privacy issues privately.

Do not include real documents or sensitive personal information in a report. Use synthetic or fully redacted examples.

## Technology

- Swift
- SwiftUI
- PDFKit
- Vision
- Apple-native frameworks only

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).

## Disclaimer

MedMaskMac is an assistive redaction tool, not a medical, legal, or compliance service. Users remain responsible for reviewing all output before sharing it.
