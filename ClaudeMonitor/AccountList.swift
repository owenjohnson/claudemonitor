import SwiftUI

// MARK: - AccountList: flat multi-account list (all accounts always expanded)

struct AccountList: View {
    let accounts: [AccountUsage]
    let onRemoveAccount: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(accounts) { accountUsage in
                AccountSection(
                    accountUsage: accountUsage,
                    onRemove: accountUsage.isCurrentAccount ? nil : {
                        onRemoveAccount?(accountUsage.account.email)
                    }
                )
                Divider()
            }
        }
    }
}
