import SwiftUI

struct AppsPage: View {
    @StateObject private var appProvider = AppProvider()
    @State private var searchText = ""
    @State private var selectedApp: OmiApp?
    @State private var showFilterSheet = false
    @State private var viewAllCategory: OmiAppCategory?

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar
                .padding()

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Content
            if appProvider.isLoading {
                loadingShimmerView
            } else if appProvider.apps.isEmpty && appProvider.popularApps.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        // Popular section (horizontal scroll)
                        if !appProvider.popularApps.isEmpty && searchText.isEmpty {
                            HorizontalAppSection(
                                title: "Popular",
                                apps: appProvider.popularApps,
                                appProvider: appProvider,
                                onSelectApp: { selectedApp = $0 }
                            )
                        }

                        // Enabled apps section (horizontal scroll)
                        if !appProvider.enabledApps.isEmpty && searchText.isEmpty {
                            HorizontalAppSection(
                                title: "Installed",
                                apps: appProvider.enabledApps,
                                appProvider: appProvider,
                                onSelectApp: { selectedApp = $0 }
                            )
                        }

                        // Chat apps section
                        if !appProvider.chatApps.isEmpty && searchText.isEmpty {
                            HorizontalAppSection(
                                title: "Chat Apps",
                                apps: appProvider.chatApps,
                                appProvider: appProvider,
                                onSelectApp: { selectedApp = $0 }
                            )
                        }

                        // All apps or search results
                        if !searchText.isEmpty {
                            AppGridSection(
                                title: "Search Results (\(appProvider.apps.count))",
                                apps: appProvider.apps,
                                appProvider: appProvider,
                                onSelectApp: { selectedApp = $0 }
                            )
                        } else {
                            // Group by category
                            ForEach(appProvider.categories) { category in
                                let categoryApps = appProvider.apps(forCategory: category.id)
                                if !categoryApps.isEmpty {
                                    HorizontalAppSection(
                                        title: category.title,
                                        apps: categoryApps,
                                        appProvider: appProvider,
                                        onSelectApp: { selectedApp = $0 },
                                        onViewAll: { viewAllCategory = category }
                                    )
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .background(OmiColors.backgroundPrimary)
        .task {
            await appProvider.fetchApps()
        }
        .onChange(of: searchText) { _, newValue in
            appProvider.searchQuery = newValue
            Task {
                // Debounce search
                try? await Task.sleep(for: .milliseconds(300))
                if appProvider.searchQuery == newValue {
                    await appProvider.searchApps()
                }
            }
        }
        .sheet(item: $selectedApp) { app in
            AppDetailSheet(app: app, appProvider: appProvider)
        }
        .sheet(isPresented: $showFilterSheet) {
            AppFilterSheet(appProvider: appProvider)
        }
        .sheet(item: $viewAllCategory) { category in
            CategoryAppsSheet(category: category, appProvider: appProvider, onSelectApp: { selectedApp = $0 })
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(OmiColors.textTertiary)

                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(OmiColors.textPrimary)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(OmiColors.backgroundSecondary)
            .cornerRadius(10)

            // Filter toggles
            FilterToggle(
                icon: "arrow.down.circle",
                label: "Installed",
                isActive: appProvider.showInstalledOnly
            ) {
                appProvider.showInstalledOnly.toggle()
                Task { await appProvider.searchApps() }
            }

            // Filter button
            Button(action: { showFilterSheet = true }) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20))
                    .foregroundColor(hasActiveFilters ? OmiColors.purplePrimary : OmiColors.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var hasActiveFilters: Bool {
        appProvider.selectedCategory != nil || appProvider.selectedCapability != nil
    }

    private var loadingShimmerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Shimmer sections
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 12) {
                        ShimmerView()
                            .frame(width: 120, height: 24)
                            .cornerRadius(6)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(0..<4, id: \.self) { _ in
                                    ShimmerAppCard()
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)

            Text("No apps found")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            if !searchText.isEmpty {
                Text("Try a different search term")
                    .foregroundColor(OmiColors.textTertiary)

                Button("Clear Search") {
                    searchText = ""
                }
                .buttonStyle(.bordered)
            } else {
                Text("Apps will appear here once available")
                    .foregroundColor(OmiColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shimmer Views

struct ShimmerView: View {
    @State private var isAnimating = false

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        OmiColors.backgroundSecondary,
                        OmiColors.backgroundTertiary,
                        OmiColors.backgroundSecondary
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .mask(Rectangle())
            .offset(x: isAnimating ? 200 : -200)
            .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

struct ShimmerAppCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShimmerView()
                .frame(width: 60, height: 60)
                .cornerRadius(12)

            ShimmerView()
                .frame(width: 80, height: 14)
                .cornerRadius(4)

            ShimmerView()
                .frame(width: 60, height: 12)
                .cornerRadius(4)
        }
        .frame(width: 100)
    }
}

// MARK: - Filter Toggle

struct FilterToggle: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? OmiColors.purplePrimary.opacity(0.2) : OmiColors.backgroundSecondary)
            .foregroundColor(isActive ? OmiColors.purplePrimary : OmiColors.textSecondary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Horizontal App Section

struct HorizontalAppSection: View {
    let title: String
    let apps: [OmiApp]
    let appProvider: AppProvider
    let onSelectApp: (OmiApp) -> Void
    var onViewAll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                if apps.count > 5, let onViewAll = onViewAll {
                    Button(action: onViewAll) {
                        HStack(spacing: 4) {
                            Text("View All")
                                .font(.system(size: 13))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(OmiColors.purplePrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(apps.prefix(10)) { app in
                        CompactAppCard(app: app, appProvider: appProvider, onSelect: { onSelectApp(app) })
                    }
                }
            }
        }
    }
}

// MARK: - Grid App Section

struct AppGridSection: View {
    let title: String
    let apps: [OmiApp]
    let appProvider: AppProvider
    let onSelectApp: (OmiApp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ], spacing: 16) {
                ForEach(apps) { app in
                    AppCard(app: app, appProvider: appProvider, onSelect: { onSelectApp(app) })
                }
            }
        }
    }
}

// MARK: - Compact App Card (for horizontal scroll)

struct CompactAppCard: View {
    let app: OmiApp
    let appProvider: AppProvider
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .center, spacing: 8) {
                // App icon
                AsyncImage(url: URL(string: app.image)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        appIconPlaceholder
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                VStack(spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.textPrimary)
                        .lineLimit(1)

                    // Rating or category
                    if let rating = app.formattedRating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.yellow)
                            Text(rating)
                                .font(.system(size: 10))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    } else {
                        Text(app.category.replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.textTertiary)
                            .lineLimit(1)
                    }
                }

                // Get/Open button
                SmallAppButton(app: app, appProvider: appProvider)
            }
            .frame(width: 90)
            .padding(.vertical, 8)
            .background(isHovering ? OmiColors.backgroundSecondary.opacity(0.5) : Color.clear)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var appIconPlaceholder: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(OmiColors.backgroundTertiary)
            .overlay(
                Image(systemName: "app.fill")
                    .foregroundColor(OmiColors.textTertiary)
            )
    }
}

// MARK: - Small App Button

struct SmallAppButton: View {
    let app: OmiApp
    let appProvider: AppProvider

    var body: some View {
        Button(action: {
            Task { await appProvider.toggleApp(app) }
        }) {
            if appProvider.isAppLoading(app.id) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 50, height: 22)
            } else {
                Text(app.enabled ? "Open" : "Get")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(app.enabled ? OmiColors.textSecondary : .white)
                    .frame(width: 50, height: 22)
                    .background(app.enabled ? OmiColors.backgroundTertiary : OmiColors.purplePrimary)
                    .cornerRadius(11)
            }
        }
        .buttonStyle(.plain)
        .disabled(appProvider.isAppLoading(app.id))
    }
}

// MARK: - App Card (Full)

struct AppCard: View {
    let app: OmiApp
    let appProvider: AppProvider
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    // App icon
                    AsyncImage(url: URL(string: app.image)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            appIconPlaceholder
                        }
                    }
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)
                            .lineLimit(1)

                        Text(app.author)
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()
                }

                Text(app.description)
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack {
                    // Rating
                    if let rating = app.formattedRating {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                            Text(rating)
                                .font(.system(size: 11))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    }

                    Spacer()

                    // Get/Open button
                    AppActionButton(app: app, appProvider: appProvider)
                }
            }
            .padding(14)
            .background(isHovering ? OmiColors.backgroundSecondary : OmiColors.backgroundPrimary)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(OmiColors.backgroundTertiary, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var appIconPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(OmiColors.backgroundTertiary)
            .overlay(
                Image(systemName: "app.fill")
                    .foregroundColor(OmiColors.textTertiary)
            )
    }
}

// MARK: - App Action Button

struct AppActionButton: View {
    let app: OmiApp
    let appProvider: AppProvider

    var body: some View {
        Button(action: {
            Task {
                await appProvider.toggleApp(app)
            }
        }) {
            if appProvider.isAppLoading(app.id) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 60, height: 28)
            } else {
                Text(app.enabled ? "Open" : "Get")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(app.enabled ? OmiColors.textSecondary : .white)
                    .frame(width: 60, height: 28)
                    .background(app.enabled ? OmiColors.backgroundTertiary : OmiColors.purplePrimary)
                    .cornerRadius(14)
            }
        }
        .buttonStyle(.plain)
        .disabled(appProvider.isAppLoading(app.id))
    }
}

// MARK: - Filter Sheet

struct AppFilterSheet: View {
    @ObservedObject var appProvider: AppProvider
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Filters")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                if hasActiveFilters {
                    Button("Clear All") {
                        appProvider.clearFilters()
                        Task { await appProvider.searchApps() }
                    }
                    .font(.system(size: 13))
                    .foregroundColor(OmiColors.purplePrimary)
                }

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(OmiColors.backgroundSecondary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()
                .background(OmiColors.backgroundTertiary)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Categories
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Category")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        FlowLayout(spacing: 8) {
                            ForEach(appProvider.categories) { category in
                                FilterChip(
                                    label: category.title,
                                    isSelected: appProvider.selectedCategory == category.id
                                ) {
                                    if appProvider.selectedCategory == category.id {
                                        appProvider.selectedCategory = nil
                                    } else {
                                        appProvider.selectedCategory = category.id
                                    }
                                    Task { await appProvider.searchApps() }
                                }
                            }
                        }
                    }

                    // Capabilities
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Capability")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        FlowLayout(spacing: 8) {
                            ForEach(appProvider.capabilities) { capability in
                                FilterChip(
                                    label: capability.title,
                                    isSelected: appProvider.selectedCapability == capability.id
                                ) {
                                    if appProvider.selectedCapability == capability.id {
                                        appProvider.selectedCapability = nil
                                    } else {
                                        appProvider.selectedCapability = capability.id
                                    }
                                    Task { await appProvider.searchApps() }
                                }
                            }
                        }
                    }

                    // Other filters
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Other")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        Toggle("Show installed only", isOn: $appProvider.showInstalledOnly)
                            .toggleStyle(SwitchToggleStyle(tint: OmiColors.purplePrimary))
                            .foregroundColor(OmiColors.textSecondary)
                            .onChange(of: appProvider.showInstalledOnly) { _, _ in
                                Task { await appProvider.searchApps() }
                            }
                    }
                }
                .padding()
            }
        }
        .frame(width: 400, height: 450)
        .background(OmiColors.backgroundPrimary)
    }

    private var hasActiveFilters: Bool {
        appProvider.selectedCategory != nil ||
        appProvider.selectedCapability != nil ||
        appProvider.showInstalledOnly
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? OmiColors.purplePrimary : OmiColors.backgroundSecondary)
                .foregroundColor(isSelected ? .white : OmiColors.textSecondary)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Category Apps Sheet

struct CategoryAppsSheet: View {
    let category: OmiAppCategory
    let appProvider: AppProvider
    let onSelectApp: (OmiApp) -> Void

    @Environment(\.dismiss) private var dismiss

    var categoryApps: [OmiApp] {
        appProvider.apps(forCategory: category.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textSecondary)
                }
                .buttonStyle(.plain)

                Text(category.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                Text("\(categoryApps.count) apps")
                    .font(.system(size: 13))
                    .foregroundColor(OmiColors.textTertiary)
            }
            .padding()

            Divider()
                .background(OmiColors.backgroundTertiary)

            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 16) {
                    ForEach(categoryApps) { app in
                        AppCard(app: app, appProvider: appProvider, onSelect: { onSelectApp(app) })
                    }
                }
                .padding()
            }
        }
        .frame(width: 600, height: 500)
        .background(OmiColors.backgroundPrimary)
    }
}

// MARK: - App Detail Sheet

struct AppDetailSheet: View {
    let app: OmiApp
    let appProvider: AppProvider

    @Environment(\.dismiss) private var dismiss
    @State private var reviews: [OmiAppReview] = []
    @State private var isLoadingReviews = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(OmiColors.backgroundSecondary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // App header
                    HStack(spacing: 16) {
                        AsyncImage(url: URL(string: app.image)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(OmiColors.backgroundTertiary)
                            }
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(app.name)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(OmiColors.textPrimary)

                            Text(app.author)
                                .font(.system(size: 14))
                                .foregroundColor(OmiColors.textTertiary)

                            HStack(spacing: 12) {
                                if let rating = app.formattedRating {
                                    HStack(spacing: 4) {
                                        Image(systemName: "star.fill")
                                            .foregroundColor(.yellow)
                                        Text("\(rating) (\(app.ratingCount))")
                                    }
                                    .font(.system(size: 13))
                                    .foregroundColor(OmiColors.textSecondary)
                                }

                                Text("\(app.installs) installs")
                                    .font(.system(size: 13))
                                    .foregroundColor(OmiColors.textSecondary)
                            }
                        }

                        Spacer()

                        // Action button
                        Button(action: {
                            Task {
                                await appProvider.toggleApp(app)
                            }
                        }) {
                            if appProvider.isAppLoading(app.id) {
                                ProgressView()
                                    .frame(width: 100, height: 36)
                            } else {
                                Text(app.enabled ? "Disable" : "Enable")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 100, height: 36)
                                    .background(app.enabled ? OmiColors.error : OmiColors.purplePrimary)
                                    .cornerRadius(18)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .background(OmiColors.backgroundTertiary)

                    // Description
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        Text(app.description)
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Capabilities
                    if !app.capabilities.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Capabilities")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(OmiColors.textPrimary)

                            FlowLayout(spacing: 8) {
                                ForEach(app.capabilities, id: \.self) { capability in
                                    CapabilityBadge(capability: capability)
                                }
                            }
                        }
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Category")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        Text(app.category.replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textSecondary)
                    }

                    // Reviews section
                    if !reviews.isEmpty {
                        Divider()
                            .background(OmiColors.backgroundTertiary)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Reviews")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(OmiColors.textPrimary)

                            ForEach(reviews.prefix(3)) { review in
                                ReviewCard(review: review)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 550)
        .background(OmiColors.backgroundPrimary)
        .task {
            await loadReviews()
        }
    }

    private func loadReviews() async {
        isLoadingReviews = true
        defer { isLoadingReviews = false }

        do {
            reviews = try await APIClient.shared.getAppReviews(appId: app.id)
        } catch {
            // Silently fail - reviews are optional
        }
    }
}

// MARK: - Capability Badge

struct CapabilityBadge: View {
    let capability: String

    var icon: String {
        switch capability {
        case "chat": return "bubble.left.and.bubble.right"
        case "memories": return "brain"
        case "persona": return "person.crop.circle"
        case "external_integration": return "link"
        case "proactive_notification": return "bell"
        default: return "app"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(capability.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OmiColors.backgroundSecondary)
        .foregroundColor(OmiColors.textSecondary)
        .cornerRadius(16)
    }
}

// MARK: - Review Card

struct ReviewCard: View {
    let review: OmiAppReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Rating stars
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= review.score ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundColor(star <= review.score ? .yellow : OmiColors.textTertiary)
                    }
                }

                Spacer()

                Text(review.ratedAt, style: .date)
                    .font(.system(size: 11))
                    .foregroundColor(OmiColors.textTertiary)
            }

            Text(review.review)
                .font(.system(size: 13))
                .foregroundColor(OmiColors.textSecondary)
                .lineLimit(3)

            if let response = review.response {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Developer Response")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)

                    Text(response)
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textSecondary)
                        .lineLimit(2)
                }
                .padding(10)
                .background(OmiColors.backgroundSecondary)
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(OmiColors.backgroundSecondary.opacity(0.5))
        .cornerRadius(10)
    }
}

// MARK: - Flow Layout Helper

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                       y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                self.size.width = max(self.size.width, x)
            }

            self.size.height = y + rowHeight
        }
    }
}

#Preview {
    AppsPage()
        .frame(width: 900, height: 700)
}
