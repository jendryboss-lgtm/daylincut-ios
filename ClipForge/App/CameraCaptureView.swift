import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Shoot and record": system camera in video mode.
struct CameraCaptureView: UIViewControllerRepresentable {
    var onFinish: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            let vc = UIHostingController(rootView: CameraUnavailableView(onClose: { onFinish(nil) }))
            return vc
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 600
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.mediaURL] as? URL)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

private struct CameraUnavailableView: View {
    var onClose: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Camera unavailable").font(.title3.bold())
            Text("This device has no camera (for example the Simulator). Pick a video from your library instead.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close", action: onClose).buttonStyle(PillButtonStyle())
        }
        .padding(32)
    }
}
