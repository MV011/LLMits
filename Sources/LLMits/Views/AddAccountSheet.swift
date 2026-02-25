import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject var accountsVM: AccountsViewModel
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var selectedProvider: Provider = .anthropic
    @State private var displayName = ""
    @State private var token = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button {
                    onCancel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Add Account")
                    .font(.system(size: 14, weight: .bold, design: .rounded))

                Spacer()

                // Spacer to balance
                Color.clear.frame(width: 56, height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.blue.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Provider picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROVIDER")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)

                        VStack(spacing: 4) {
                            ForEach(Provider.allCases) { provider in
                                Button {
                                    selectedProvider = provider
                                } label: {
                                    HStack(spacing: 10) {
                                        provider.icon
                                            .frame(width: 20, height: 20)

                                        Text(provider.displayName)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(.primary)

                                        Spacer()

                                        if selectedProvider == provider {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedProvider == provider
                                                ? Color.blue.opacity(0.08)
                                                : Color.primary.opacity(0.03))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(
                                                selectedProvider == provider
                                                    ? Color.blue.opacity(0.3)
                                                    : Color.clear,
                                                lineWidth: 1
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Display name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DISPLAY NAME")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)

                        TextField("e.g. Personal Account", text: $displayName)
                            .font(.system(size: 12, design: .rounded))
                            .textFieldStyle(.roundedBorder)
                    }

                    // Token
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SESSION TOKEN")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)

                        Text(selectedProvider.tokenLabel)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 2)

                        SecureField("Paste token here…", text: $token)
                            .font(.system(size: 12, design: .rounded))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            Spacer(minLength: 0)

            Divider()
                .padding(.horizontal, 8)

            // Save button
            HStack {
                Spacer()
                Button {
                    let name = displayName.isEmpty
                        ? "\(selectedProvider.displayName) Account"
                        : displayName
                    accountsVM.addAccount(
                        provider: selectedProvider,
                        displayName: name,
                        token: token.isEmpty ? "mock-token" : token
                    )
                    onDone()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                        Text("Add Account")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 12)
        }
    }
}
