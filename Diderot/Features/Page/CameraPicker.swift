import SwiftUI
import UIKit

/// Camera via `UIImagePickerController`; delivers the captured photo as JPEG.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            guard let image = info[.originalImage] as? UIImage else { return }
            let onCapture = parent.onCapture
            Task {
                // A full-resolution photo takes a while to encode: not on the main thread, where it held up the UI.
                let data = await Task.detached(priority: .userInitiated) { image.jpegData(compressionQuality: 0.9) }.value
                if let data { onCapture(data) }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
