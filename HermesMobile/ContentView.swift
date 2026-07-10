import SwiftUI

struct ContentView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @State private var pendingSharedImport: SharedImport?
    @State private var pendingDeepLinkedSessionID: String?
    @State private var pendingNewChatRequest: NewChatRequest?
    @State private var didCheckInitialPendingShare = false
    @State private var intentRouter = AppIntentRouter.shared

    var body: some View {
        content
            .onOpenURL(perform: handleOpenURL)
            .task {
                guard !didCheckInitialPendingShare else { return }
                didCheckInitialPendingShare = true
                importPendingSharedDraftIfAvailable()
                // Cold launch: an App Intent may have queued a deep link before this
                // view appeared (e.g. Action button "New Chat"). Drain it now (#337).
                drainPendingIntentDeepLink()
            }
            .onChange(of: intentRouter.pendingDeepLink) {
                // Warm launch: the intent set the deep link after the view appeared.
                drainPendingIntentDeepLink()
            }
            .task {
                // #246: on cold launch, end any Live Activity left "running" by a
                // run that finished while the app was terminated. #248: this is also
                // the one pass allowed to fire a recent run's "response complete"
                // notification, since a relaunch means it finished while not active.
                await reconcileOrphanedLiveActivities(notifiesOnCompletion: true)
            }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                importPendingSharedDraftIfAvailable()
                // #248: the foreground pass stays silent — the in-session completion
                // paths own notifications while the app is alive.
                Task { await reconcileOrphanedLiveActivities(notifiesOnCompletion: false) }
            }
    }

    private func reconcileOrphanedLiveActivities(notifiesOnCompletion: Bool) async {
        guard case let .loggedIn(server) = authManager.state else { return }
        await LiveActivityReconciler.reconcileOrphanedActivities(
            server: server,
            notifiesOnCompletion: notifiesOnCompletion,
            preferenceEnabled: isResponseCompletionNotificationsEnabled
        )
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .unconfigured:
            OnboardingView(authManager: authManager)
        case .loggedOut(let server):
            OnboardingView(authManager: authManager, savedServer: server)
        case .loggedIn(let server):
            SessionRootView(
                authManager: authManager,
                server: server,
                pendingSharedImport: $pendingSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest
            )
            // Switching the active server keeps us in `.loggedIn`, so without a
            // per-server identity SwiftUI would reuse the same SessionListView (and
            // its server-bound view model), leaving stale sessions/chat on screen.
            // Keying on the server tears the whole stack down and rebuilds it
            // against the newly active server (#17).
            .id(server)
        }
    }

    private func handleOpenURL(_ url: URL) {
        // A fresh request each time (new `id`) so a repeat invocation re-triggers navigation
        // even if the previous one's value still lingers downstream. The voice variant carries
        // `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).
        if HermesDeepLink.isNewChatVoiceURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: true)
            return
        }

        // The profile variant carries the chosen profile name, so the composer creates the
        // session pinned to it (#339). A malformed link with no profile falls back to a
        // plain new chat (server's active profile) rather than failing.
        if HermesDeepLink.isNewChatInProfileURL(url) {
            pendingNewChatRequest = NewChatRequest(
                profileName: HermesDeepLink.profileName(fromNewChatInProfile: url)
            )
            return
        }

        if HermesDeepLink.isNewChatURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: false)
            return
        }

        if let sessionID = HermesDeepLink.sessionID(from: url) {
            pendingDeepLinkedSessionID = sessionID
            return
        }

        guard HermesShareDraft.isShareOpenURL(url) else {
            return
        }

        importPendingSharedDraftIfAvailable()
    }

    /// Routes a deep link queued by an App Intent through the same `handleOpenURL` parser
    /// used for external URLs, then clears it so it routes exactly once (#337).
    private func drainPendingIntentDeepLink() {
        guard let url = intentRouter.pendingDeepLink else { return }
        intentRouter.pendingDeepLink = nil
        handleOpenURL(url)
    }

    private func importPendingSharedDraftIfAvailable() {
        guard let directory = HermesShareDraft.containerURL() else {
            return
        }

        do {
            if let sharedImport = try HermesShareDraft.loadPendingImport(from: directory) {
                pendingSharedImport = sharedImport
            }
        } catch {
            pendingSharedImport = nil
        }
    }
}


struct SessionRootView: View {
    private enum SessionSplitDetail: Identifiable {
        case session(SessionSummary)
        case newChat(PendingNewChatRoute)
        case utility(SessionListUtilityDestination)

        var id: String {
            switch self {
            case .session(let session):
                return "session:\(session.id)"
            case .newChat(let route):
                return "new-chat:\(route.id.uuidString)"
            case .utility(let destination):
                return "utility:\(destination.id)"
            }
        }
    }

    @Bindable var authManager: AuthManager
    let server: URL
    @Binding var pendingSharedImport: SharedImport?
    @Binding var pendingDeepLinkedSessionID: String?
    @Binding var requestedNewChat: NewChatRequest?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedDetail: SessionSplitDetail?

    private var usesExpandedLayout: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if usesExpandedLayout {
                expandedLayout
            } else {
                sessionList()
            }
        }
    }

    private var expandedLayout: some View {
        NavigationSplitView {
            sessionList(
                onOpenSession: { selectedDetail = .session($0) },
                onOpenNewChat: { selectedDetail = .newChat($0) },
                onOpenUtilityDestination: { selectedDetail = .utility($0) }
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            splitDetailView
        }
    }

    @ViewBuilder
    private var splitDetailView: some View {
        switch selectedDetail {
        case .session(let session):
            ChatView(session: session, server: server, onAPIError: authManager.handleAPIError)
                .id("session:\(session.id)")
        case .newChat(let route):
            PendingNewChatView(
                initialDraft: route.initialDraft,
                initialAttachments: route.initialAttachments,
                autoStartsVoiceInput: route.autoStartsVoiceInput,
                profileName: route.profileName,
                server: server,
                viewModel: SessionListViewModel(server: server),
                onAPIError: authManager.handleAPIError
            )
            .id("new-chat:\(route.id.uuidString)")
        case .utility(let destination):
            utilityDetailView(destination)
        case nil:
            ContentUnavailableView(
                "Select a Session",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a conversation from the sidebar.")
            )
        }
    }

    @ViewBuilder
    private func utilityDetailView(_ destination: SessionListUtilityDestination) -> some View {
        switch destination {
        case .settings(let scrollTo):
            SettingsView(authManager: authManager, server: server, initialScrollTarget: scrollTo)
        case .tasks:
            TasksView(server: server, onAPIError: authManager.handleAPIError)
        case .skills:
            SkillsView(server: server, onAPIError: authManager.handleAPIError)
        case .memory:
            MemoryView(server: server, onAPIError: authManager.handleAPIError)
        case .insights:
            InsightsView(server: server, onAPIError: authManager.handleAPIError)
        case .archived:
            ArchivedSessionsView(server: server, onAPIError: authManager.handleAPIError)
        }
    }

    private func sessionList(
        onOpenSession: ((SessionSummary) -> Void)? = nil,
        onOpenNewChat: ((PendingNewChatRoute) -> Void)? = nil,
        onOpenUtilityDestination: ((SessionListUtilityDestination) -> Void)? = nil
    ) -> some View {
        SessionListView(
            authManager: authManager,
            server: server,
            pendingSharedImport: $pendingSharedImport,
            pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
            requestedNewChat: $requestedNewChat,
            onOpenSession: onOpenSession,
            onOpenNewChat: onOpenNewChat,
            onOpenUtilityDestination: onOpenUtilityDestination
        )
    }
}

#Preview {
    ContentView(authManager: AuthManager())
}
