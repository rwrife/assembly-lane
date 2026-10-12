import AssemblyLaneKit
import PhotosUI
import SwiftUI
import UIKit

/// Render only for a deliberate user-owned step. Picker access is user-scoped;
/// no Photo Library enumeration or blanket permission request.
struct ScopedPhotoImport: View {
    let store: LocalProjectStore
    let projectId: UUID
    let stepId: UUID
    let didImport: (UUID) -> Void

    @State private var selection: PhotosPickerItem?
    @State private var showCamera = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            PhotosPicker(selection: $selection, matching: .images) {
                Label("Choose step photo", systemImage: "photo")
            }
            .accessibilityIdentifier("step.photo.choose")

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Take step photo", systemImage: "camera")
                }
                .accessibilityIdentifier("step.photo.camera")
            }
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data),
                          let jpeg = image.jpegData(compressionQuality: 0.85) else {
                        throw LocalProjectStore.StoreError.invalidImage
                    }
                    let id = try store.attachPhoto(jpeg, projectId: projectId, stepId: stepId)
                    didImport(id)
                } catch {
                    errorMessage = "Photo could not be saved. Please try again."
                }
                selection = nil
            }
        }
        .sheet(isPresented: $showCamera) {
            StepCamera { image in
                do {
                    guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
                        throw LocalProjectStore.StoreError.invalidImage
                    }
                    didImport(try store.attachPhoto(jpeg, projectId: projectId, stepId: stepId))
                } catch {
                    errorMessage = "Photo could not be saved. Please try again."
                }
            }
        }
        .alert("Photo not saved", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct StepCamera: UIViewControllerRepresentable {
    let didCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(didCapture: didCapture, dismiss: dismiss)
    }

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let didCapture: (UIImage) -> Void
        let dismiss: DismissAction

        init(didCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.didCapture = didCapture
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { didCapture(image) }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
