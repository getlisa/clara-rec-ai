import SwiftUI

/// Searches Clara's own customers, and creates one when the job is for somebody new.
struct CustomerPicker: View {
    let store: QuoteStore

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var customers: [QboCustomer] = []
    @State private var isLoading = true
    @State private var showingCreate = false

    private let companies = CompaniesAPI()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Create a new customer", systemImage: "person.badge.plus") {
                        showingCreate = true
                    }
                }

                Section {
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if customers.isEmpty {
                        Text(search.isEmpty ? "No customers yet." : "No matches for “\(search)”.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(customers) { customer in
                            Button {
                                dismiss()
                                Task { await store.setCustomer(id: customer.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(customer.displayName)
                                        if let email = customer.email, !email.isEmpty {
                                            Text(email).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if customer.id == store.quote.customerId {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if store.quote.customerId != nil {
                    Section {
                        Button("Unlink customer", role: .destructive) {
                            dismiss()
                            Task { await store.setCustomer(id: nil) }
                        }
                    }
                }
            }
            .navigationTitle("Customer")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search customers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task(id: search) {
                isLoading = customers.isEmpty
                customers = (try? await companies.qboCustomers(search: search)) ?? []
                isLoading = false
            }
            .sheet(isPresented: $showingCreate) {
                CreateCustomerForm { created in
                    showingCreate = false
                    guard let created else { return }
                    dismiss()
                    Task { await store.setCustomer(id: created.customerId) }
                }
            }
        }
    }
}

/// Creating a customer from the estimate. The server never guesses an address — when it reports
/// `addressMissing`, those parts are asked for rather than invented.
private struct CreateCustomerForm: View {
    let onFinish: (CreatedCustomer?) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var address = ""
    @State private var working = false
    @State private var error: String?
    @State private var missing: [String] = []

    private let companies = CompaniesAPI()

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !working
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Name", text: $name)
                        .textContentType(.organizationName)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                }

                Section {
                    TextField("Street, city, state, ZIP", text: $address, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Address")
                } footer: {
                    if missing.isEmpty {
                        Text("Used on the proposal document.")
                    } else {
                        Text("Still needed: \(missing.joined(separator: ", ")). The server does not guess these.")
                            .foregroundStyle(.orange)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("New customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onFinish(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let created = try await companies.createCustomer(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: email, phone: phone, address: address
                )
                if let gaps = created.addressMissing, !gaps.isEmpty, address.isEmpty {
                    // Created, but the proposal will be missing address parts — say which, and
                    // let them fill it in before moving on.
                    missing = gaps
                    error = "Customer created. Add the missing address parts above, or continue."
                    return
                }
                onFinish(created)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
