import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var viewModel = DetectionViewModel()
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        if let resultImage = viewModel.annotatedImage {
                            Image(uiImage: resultImage)
                                .resizable()
                                .scaledToFit()
                                .cornerRadius(12)
                                .padding(.horizontal)

                            if !viewModel.detections.isEmpty {
                                WoundInfoPanel(detections: viewModel.detections)
                                    .padding(.horizontal)
                            } else if viewModel.hasRunInference {
                                Text("No objects detected")
                                    .foregroundColor(.secondary)
                                    .padding()
                            }

                            HStack(spacing: 16) {
                                Button(action: { saveImage() }) {
                                    Label("Save", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(.bordered)

                                Button(action: { showShareSheet = true }) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.bottom)
                        } else if viewModel.isProcessing {
                            ProgressView("Running inference...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.top, 100)
                        } else {
                            VStack(spacing: 16) {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 80))
                                    .foregroundColor(.secondary)

                                Text("Wound Detector")
                                    .font(.largeTitle)
                                    .fontWeight(.bold)

                                Text("Take or select a photo to detect and classify pressure injury stages")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 40)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                    }
                }

                VStack(spacing: 12) {
                    ModelPickerView(viewModel: viewModel)

                    Button(action: { showCamera = true }) {
                        Label("Take Photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isModelLoading)

                    Button(action: { showPhotoPicker = true }) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.isModelLoading)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
            }
            .navigationTitle("Wound Detector")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCamera) {
                ImagePicker(sourceType: .camera) { image in
                    viewModel.runInference(on: image)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoLibraryPicker { image in
                    viewModel.runInference(on: image)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let image = viewModel.annotatedImage {
                    ShareSheet(items: [image])
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
        }
    }

    private func saveImage() {
        guard let image = viewModel.annotatedImage else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}
