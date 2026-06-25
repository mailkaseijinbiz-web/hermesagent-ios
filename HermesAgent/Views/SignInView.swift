import SwiftUI
import GoogleSignInSwift

struct SignInView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Color.accentColor.opacity(0.04)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    ZStack {
                        Circle().fill(.ultraThinMaterial).frame(width: 100, height: 100)
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 48, weight: .light))
                    }
                    Text("HermesAgent")
                        .font(.system(size: 32, weight: .light))
                        .tracking(1.5)
                    Text("Googleアカウントでサインイン")
                        .font(.system(.subheadline, weight: .light))
                        .foregroundStyle(.secondary)
                }

                if let err = auth.authError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                GoogleSignInButton(scheme: .light, style: .wide) {
                    auth.signIn()
                }
                .frame(height: 50)
                .padding(.horizontal, 48)

                Spacer()

                Text("iPhone・iPad・Mac で同じGoogleアカウントを使うと\n同じセッションに接続できます")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
            }
        }
    }
}
