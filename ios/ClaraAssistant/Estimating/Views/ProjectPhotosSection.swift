import PhotosUI
import SwiftUI

/// Photos attached to the quote — they never reach the agent, and appear as the PROJECT PHOTOS
/// section at the end of the proposal PDF and .docx.
///
/// The glasses shutter is the reason this app exists rather than the web one: a technician with
/// tools in both hands captures the equipment without touching the phone.
struct ProjectPhotosSection: View {
    let store: QuoteStore

    @State private var controller = GlassesController.shared
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var preview: QuoteImage?
    @State private var showGlassesGallery = false
    @AppStorage(AppSettings.handsFreeCaptureKey) private var handsFree = true

    private var frozen: Bool { store.quote.isFrozen }

    var body: some View {
        Section {
            if store.images.isEmpty {
                Text("No photos yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.images) { image in
                            thumbnail(image)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if !frozen {
                Button {
                    Task {
                        guard let jpeg = await controller.captureStill() else { return }
                        await store.attachPhotos([jpeg])
                    }
                } label: {
                    HStack {
                        Label(shutterTitle, systemImage: "eyeglasses")
                        Spacer()
                        if controller.captureStatus != .idle { ProgressView() }
                    }
                }
                .disabled(controller.captureStatus != .idle || store.isBusy)

                // Hands-free: press the button on the glasses and the photo lands here by
                // itself. The SDK never publishes that button press, but the photo travels
                // glasses → Meta AI app → photo library, and the library tells us when it lands.
                Toggle(isOn: Binding(
                    get: { handsFree },
                    set: { wanted in
                        handsFree = wanted
                        store.setAutoImport(wanted)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Hands-free capture", systemImage: "hand.raised.slash")
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(store.isAutoImportOn ? Color.accentColor : .secondary)
                    }
                }

                if let problem = store.autoImportProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // Fallbacks for anything taken before hands-free was switched on.
                Menu {
                    Button("From glasses gallery", systemImage: "photo.stack") {
                        showGlassesGallery = true
                    }
                    PhotosPicker(selection: $pickerItems, matching: .images) {
                        Label("From photo library", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label("Add an earlier photo", systemImage: "plus")
                }
                .disabled(store.isBusy)
            }
        } header: {
            HStack {
                Text("Project photos")
                Spacer()
                if !store.images.isEmpty { Text("\(store.images.count)") }
            }
        } footer: {
            if !frozen {
                Text("Press the button on your glasses as you work — Meta only transfers photos once the glasses are folded or in their case, and they are added here then. For a photo right now, use \"Take a photo with the glasses\" above.\n\nPhotos appear at the end of the proposal document. They are not sent to the assistant.")
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var jpegs: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { jpegs.append(data) }
                }
                pickerItems = []
                await store.attachPhotos(jpegs)
            }
        }
        .sheet(isPresented: $showGlassesGallery) {
            GlassesGalleryPicker(store: store)
        }
        .sheet(item: $preview) { image in
            NavigationStack {
                AsyncImage(url: URL(string: image.url)) { rendered in
                    rendered.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .navigationTitle(image.filename ?? "Photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { preview = nil }
                    }
                    if !frozen {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Delete", role: .destructive) {
                                preview = nil
                                Task { await store.removeImage(image.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var statusLine: String {
        // Meta's glasses only transfer media once they are folded or in the case, so promising
        // anything sooner sets the technician waiting for a photo that physically cannot arrive.
        if store.isAutoImportOn { return "On — photos import when you fold your glasses" }
        if handsFree { return "Waiting for your glasses to sync" }
        return "Photos from your glasses are added to this estimate automatically"
    }

    private var shutterTitle: String {
        switch controller.captureStatus {
        case .preparing: return "Waking the glasses…"
        case .capturing: return "Capturing…"
        case .idle: return "Take a photo with the glasses"
        }
    }

    private func thumbnail(_ image: QuoteImage) -> some View {
        Button { preview = image } label: {
            RemoteThumbnail(urlString: image.url, width: 78, height: 60)
        }
        .buttonStyle(.plain)
    }
}

/// A photo from the quote's gallery.
///
/// The URL is a time-limited S3 link, so it can legitimately fail — expired, offline, or revoked.
/// Rendering that as a permanent spinner makes a broken image look like a slow one.
struct RemoteThumbnail: View {
    let urlString: String
    var width: CGFloat = 78
    var height: CGFloat = 60

    var body: some View {
        AsyncImage(url: URL(string: urlString)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .empty:
                ZStack {
                    Color.secondary.opacity(0.12)
                    ProgressView().controlSize(.small)
                }
            @unknown default:
                Color.secondary.opacity(0.12)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// The company's sales-tax rates, plus an explicit "untaxed" choice.
struct TaxRateSheet: View {
    let currentSalesTaxId: Int?
    let currentRatePercent: Double?
    let taxableSubtotal: Double?
    let onPick: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var settings: SalesTaxSettings?
    @State private var isLoading = true

    private var rates: [SalesTaxRate] { settings?.offerableRates ?? [] }

    private let companies = CompaniesAPI()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rates) { rate in
                        Button { onPick(rate.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rate.name)
                                    Text("\(rate.ratePercent.formatted())%\(rate.source.map { " · \($0.capitalized)" } ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if rate.id == currentSalesTaxId {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if rates.isEmpty {
                        Text(settings?.isTaxEnabled == false
                             ? "Tax is switched off for this company."
                             : "No usable sales-tax rates configured for this company.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Rates")
                } footer: {
                    if let subtotal = taxableSubtotal {
                        Text("Applies to \(money(subtotal)) of taxable lines.")
                    }
                }

                Section {
                    // Marks the job deliberately untaxed, which the server records as a decision —
                    // so completing does not put the company default back on an exempted job.
                    Button("No tax on this estimate", role: .destructive) { onPick(nil) }
                } footer: {
                    Text("Records this estimate as deliberately untaxed.")
                }
            }
            .navigationTitle("Sales tax")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                settings = try? await companies.salesTaxSettings()
                isLoading = false
            }
        }
    }
}
