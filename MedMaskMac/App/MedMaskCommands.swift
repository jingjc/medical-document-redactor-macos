import SwiftUI

struct MedMaskCommands: Commands {
    @ObservedObject var viewModel: AppViewModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(L10n.Review.undo) {
                viewModel.undoCurrentPageEdit()
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!viewModel.isReviewPageActive || !viewModel.isEditingEnabled || !viewModel.canUndoCurrentPageEdit)

            Button(L10n.Review.redo) {
                viewModel.redoCurrentPageEdit()
            }
            .keyboardShortcut("Z", modifiers: [.command, .shift])
            .disabled(!viewModel.isReviewPageActive || !viewModel.isEditingEnabled || !viewModel.canRedoCurrentPageEdit)
        }

        CommandGroup(after: .saveItem) {
            Button(L10n.Export.exportButton) {
                viewModel.beginExportFlow()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(!viewModel.canBeginExportFlow)
        }

        CommandMenu(L10n.Review.commandMenuTitle) {
            Button(L10n.Review.previousPage) {
                viewModel.goToPreviousPage()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!viewModel.isReviewPageActive || !viewModel.canGoToPreviousPage)

            Button(L10n.Review.nextPage) {
                viewModel.goToNextPage()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!viewModel.isReviewPageActive || !viewModel.canGoToNextPage)

            Divider()

            Button(viewModel.previewDisplayMode.toggleMenuTitle) {
                viewModel.togglePreviewDisplayMode()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!viewModel.isReviewPageActive || !viewModel.hasImportedFiles)

            Button(L10n.Review.deleteRegion) {
                viewModel.deleteSelectedRegion()
            }
            .disabled(!viewModel.isReviewPageActive || !viewModel.canDeleteSelectedRegion)
        }
    }
}
