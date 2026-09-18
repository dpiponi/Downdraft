import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The SwiftUI file importer has no way to choose its initial Files location.
/// This small wrapper retains the normal native picker while allowing the
/// document switcher to begin beside an already-open PDF.
struct PDFDocumentPicker: UIViewControllerRepresentable {
    let startingDirectory: URL?
    let onResult: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf])
        picker.allowsMultipleSelection = false
        picker.directoryURL = startingDirectory
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        // A picker is presented for one location at a time. Updating its
        // directory while it is visible would be surprising to the reader.
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onResult: (Result<[URL], Error>) -> Void

        init(onResult: @escaping (Result<[URL], Error>) -> Void) {
            self.onResult = onResult
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onResult(.success(urls))
        }
    }
}
