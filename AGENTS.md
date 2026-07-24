# MedMaskMac — Project Instructions for AI Agents

## Project identity
MedMaskMac is a local-first macOS app for redacting sensitive information from Chinese medical documents (PDFs and images) before users share them with AI tools or other people. Privacy is the core product constraint, not a feature.

## Tech stack
- Swift + SwiftUI
- PDFKit for PDF rendering
- Vision for on-device OCR
- Apple-native frameworks only; no third-party dependencies
- Single-window macOS app; no persistence of document contents

## Current state
- Three-page flow is implemented: Import → Review/Edit → Export summary.
- On-device OCR candidate detection is implemented in `MedMaskMac/Services/OCRService.swift` (names, phone numbers, ID numbers, medical record numbers, dates, hospitals, departments, emails, staff signatures in Strict mode).
- Three redaction presets: Standard, Strict, Custom.
- Manual box editing: draw, move, resize, delete, undo/redo.
- Export rasterizes pages (200 DPI) and burns opaque black masks; originals are never modified; output filenames are uniquified to avoid overwriting.
- DEBUG-only OCR regression checks live in `OCRService.swift` behind `#if DEBUG` and use synthetic samples only.

## Hard privacy rules
Do not violate any of these in any change:
1. Local-first: no networking, no cloud OCR, no telemetry or analytics, no accounts, no cloud sync.
2. Never add logging that prints OCR text or document contents.
3. Never commit real personal, medical, financial, or identity data. Test data must be synthetic or fully redacted. Real fixtures stay outside the repository.
4. Exported copies must be irreversible: burned raster masks, never removable PDF annotations.
5. Original input files must never be modified or overwritten.
6. The ignored in-repository `Docs/` directory may be visible in Xcode only as a non-target folder reference. Its contents must never be added to build phases or Git.

## Development rules
1. Prefer small, compilable, incremental changes.
2. Do not introduce third-party dependencies.
3. Keep names clean, explicit, and maintainable.
4. Never silently expand product scope.
5. Verify changes with:
   `xcodebuild -project MedMaskMac.xcodeproj -scheme MedMaskMac -configuration Debug build`
6. Before any commit, run:
   `/usr/bin/xcrun swift Scripts/privacy_guard.swift --worktree`
   Keep the repository-managed hooks enabled with:
   `Scripts/install_privacy_hooks.sh`
