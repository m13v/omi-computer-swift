import SwiftUI

/// Search bar component for Rewind with app filter and date picker
struct RewindSearchBar: View {
    @Binding var searchQuery: String
    @Binding var selectedApp: String?
    @Binding var selectedDate: Date
    let availableApps: [String]
    let isSearching: Bool
    let onAppFilterChanged: (String?) -> Void
    let onDateChanged: (Date) -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(OmiColors.textTertiary)

                TextField("Search screenshots...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .foregroundColor(OmiColors.textPrimary)

                if isSearching {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                }

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(OmiColors.backgroundTertiary)
            .cornerRadius(8)

            // Filters row
            HStack(spacing: 12) {
                // App filter
                Menu {
                    Button("All Apps") {
                        selectedApp = nil
                        onAppFilterChanged(nil)
                    }

                    Divider()

                    ForEach(availableApps, id: \.self) { app in
                        Button(app) {
                            selectedApp = app
                            onAppFilterChanged(app)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "app.badge")
                            .font(.system(size: 12))

                        Text(selectedApp ?? "All Apps")
                            .font(.system(size: 13))

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(selectedApp != nil ? OmiColors.purplePrimary : OmiColors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedApp != nil ? OmiColors.purplePrimary.opacity(0.15) : OmiColors.backgroundTertiary)
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)

                // Date picker
                DatePicker(
                    "",
                    selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .onChange(of: selectedDate) { _, newDate in
                    onDateChanged(newDate)
                }

                Spacer()

                // Quick date buttons
                HStack(spacing: 8) {
                    quickDateButton("Today", date: Date())
                    quickDateButton("Yesterday", date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
                }
            }
        }
    }

    private func quickDateButton(_ title: String, date: Date) -> some View {
        let isSelected = Calendar.current.isDate(selectedDate, inSameDayAs: date)

        return Button {
            selectedDate = date
            onDateChanged(date)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? OmiColors.purplePrimary : OmiColors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? OmiColors.purplePrimary.opacity(0.15) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
