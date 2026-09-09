import SwiftUI
import SwiftData

struct RootView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    /// One recognizer for the app. It lives here rather than in the capture
    /// bar because the listening overlay covers the whole screen and the
    /// capture bar is only a strip of it.
    @State private var voice = VoiceCapture()

    var body: some View {
        @Bindable var settings = settings

        Group {
            if settings.hasCompletedSetup {
                tabs
            } else {
                BudgetSetupView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Control Center and the widgets leave a note rather than
            // presenting anything themselves; this is where it's picked up.
            if phase == .active { router.consumePendingAction() }
            // Nothing good comes of a mic left open behind the app switcher.
            if phase != .active { voice.cancel() }
        }
        .onOpenURL { url in
            if let action = QuickAction(url: url) { router.handle(action) }
        }
    }

    private var tabs: some View {
        @Bindable var router = router

        return TabView(selection: $router.tab) {
            Tab("Budget", systemImage: "chart.pie.fill", value: AppRouter.Tab.budget) {
                DashboardView()
            }
            Tab("Pace", systemImage: "chart.xyaxis.line", value: AppRouter.Tab.pace) {
                PaceView()
            }
            Tab("History", systemImage: "list.bullet", value: AppRouter.Tab.history) {
                HistoryView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppRouter.Tab.settings) {
                SettingsView()
            }
        }
        // The single most important affordance in the app: a capture bar that
        // never scrolls away, on every tab, one gesture from a logged purchase.
        .tabViewBottomAccessory {
            QuickAddAccessory(voice: voice)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay {
            // The animation lives in here rather than on the TabView, so it
            // fades the overlay without also animating whatever tab is behind
            // it.
            ZStack {
                if voice.isBusy { ListeningOverlay(voice: voice) }
            }
            .animation(.smooth(duration: 0.22), value: voice.isBusy)
        }
        .sheet(item: $router.entry) { request in
            AddPurchaseView(request: request)
        }
        .sheet(isPresented: $router.showingScreenshotImport) {
            ScreenshotImportView()
        }
        .sheet(item: $router.categorizing) { transaction in
            CategorizeSheet(transaction: transaction)
        }
    }
}

/// The persistent capture bar docked above the tab bar.
///
/// It sits in the tab bar's own glass, so it costs no screen real estate and
/// is always within thumb reach. Three gestures, in order of how often they're
/// wanted:
///
/// - **Hold and speak.** The mic is open only while your thumb is down, and
///   letting go shows you what was heard before anything is written.
/// - **Slide up.** Straight to the fields, for when you can't talk.
/// - **Tap.** Too short to have said anything, so it means the same thing as
///   sliding up rather than being a dead press.
private struct QuickAddAccessory: View {

    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    let voice: VoiceCapture

    /// When the finger went down, and the task that opens the mic shortly
    /// after it did.
    @State private var pressStartedAt: Date?
    @State private var openingMic: Task<Void, Never>?
    @State private var startFailure: VoiceCapture.Outcome?
    @State private var didSlideUp = false
    /// A sentence shown in place of the label for a moment -- "I didn't catch
    /// that" and friends, which don't deserve a sheet of their own.
    @State private var flash: String?

    /// How far up the thumb has to travel before a hold becomes "give me the
    /// keyboard instead".
    private static let slideDistance: CGFloat = -44
    /// Below this, a press is a tap rather than a hold.
    private static let holdSeconds: TimeInterval = 0.3

    var body: some View {
        HStack(spacing: 10) {
            speakButton

            Button {
                router.showingScreenshotImport = true
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add from a screenshot")
        }
        .padding(.horizontal, 16)
        .sensoryFeedback(.impact, trigger: voice.phase == .listening)
    }

    private var speakButton: some View {
        HStack(spacing: 8) {
            Image(systemName: voice.isBusy ? "waveform" : "mic.fill")
                .font(.title3)
                .foregroundStyle(voice.isBusy ? .red : .primary)
                .symbolEffect(.variableColor.iterative, isActive: voice.phase == .listening)

            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .contentTransition(.opacity)

            Spacer(minLength: 0)

            if !voice.isBusy {
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.smooth, value: label)
        .contentShape(.rect)
        .gesture(hold)
        .accessibilityElement()
        .accessibilityLabel("Add a purchase")
        .accessibilityHint("Hold to speak it, or swipe up to type it")
        .accessibilityAddTraits(.isButton)
        // VoiceOver users can't hold a button down, so the plain activation
        // has to land somewhere useful.
        .accessibilityAction { router.entry = .manual }
    }

    private var label: String {
        if let flash { return flash }
        switch voice.phase {
        case .listening: return "Listening…"
        case .settling: return "One moment…"
        case .idle: return "Hold to speak"
        }
    }

    // MARK: - The gesture

    private var hold: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStartedAt == nil { beginPress() }
                if !didSlideUp, value.translation.height < Self.slideDistance {
                    didSlideUp = true
                    abandonPress()
                    router.entry = .manual
                }
            }
            .onEnded { _ in
                guard !didSlideUp else {
                    didSlideUp = false
                    return
                }
                endPress()
            }
    }

    private func beginPress() {
        pressStartedAt = .now
        flash = nil
        startFailure = nil

        // The mic waits a beat before opening, so a slide up never blips it on
        // and a stray tap never asks for the microphone at all.
        openingMic = Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            startFailure = await voice.start(hints: categories.map(\.name))
        }
    }

    private func abandonPress() {
        openingMic?.cancel()
        openingMic = nil
        pressStartedAt = nil
        voice.cancel()
    }

    private func endPress() {
        let held = pressStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        let opening = openingMic
        pressStartedAt = nil
        openingMic = nil

        Task {
            if held < Self.holdSeconds { opening?.cancel() }
            // Let the opener finish either way, so we know whether there's a
            // mic to close and whether it failed for a reason worth saying.
            await opening?.value

            if let failure = startFailure {
                startFailure = nil
                voice.cancel()
                handle(failure)
            } else if held < Self.holdSeconds {
                voice.cancel()
                router.entry = .manual
            } else {
                handle(await voice.finish())
            }
        }
    }

    private func handle(_ outcome: VoiceCapture.Outcome) {
        switch outcome {
        case .heard(let sentence):
            let parsed = PurchaseTextParser.parseSpokenEntry(
                sentence,
                categoryNames: categories.map(\.name),
                defaultCurrency: settings.homeCurrencyCode
            )
            router.entry = .heard(sentence, draft: PurchaseDraft(parsed))

        case .nothingHeard:
            show("I didn't catch that")

        case .askedForPermission:
            show("Ready. Hold to speak")

        case .unavailable(let reason):
            router.entry = .couldNotListen(reason)
        }
    }

    private func show(_ message: String) {
        flash = message
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if flash == message { flash = nil }
        }
    }
}

/// What's on screen while your thumb is down.
///
/// It covers everything on purpose: you're talking, not reading, and the one
/// thing worth seeing is that the words are landing.
private struct ListeningOverlay: View {

    let voice: VoiceCapture

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(.red.opacity(0.20))
                        .frame(width: 120 + 90 * voice.level, height: 120 + 90 * voice.level)
                        .blur(radius: 14)

                    Image(systemName: "waveform")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative, isActive: voice.phase == .listening)
                }
                .animation(.smooth(duration: 0.15), value: voice.level)

                Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .animation(.smooth, value: voice.transcript)

                Spacer()

                Text("Let go to check it  ·  Slide up to type instead")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 130)
            }
        }
        // The thumb that opened this is still on the capture bar underneath.
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// Lets `sheet(item:)` drive off the transaction being categorized.
extension Transaction: Identifiable {
    var id: UUID { uuid }
}
