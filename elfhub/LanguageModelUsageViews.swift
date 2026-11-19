//
//  LanguageModelUsageViews.swift
//  elfhub
//
//  Settings › General › Usage and cost: the tokens elfhub's model requests
//  used and their estimated cost, for today, the last 7 or 30 days or all
//  time — in all, per model and per kind of work — from the counts in
//  `LanguageModelUsageLedger`. A model the price list doesn't know can be
//  given a price here.
//

import SwiftUI

enum LanguageModelUsageFormatting {
    /// 950, 12.4K, 3.2M.
    static func compactTokenCount(_ tokenCount: Int) -> String {
        let absoluteCount = Double(tokenCount)
        if absoluteCount >= 1_000_000_000 { return String(format: "%.1fB", absoluteCount / 1_000_000_000) }
        if absoluteCount >= 1_000_000 { return String(format: "%.1fM", absoluteCount / 1_000_000) }
        if absoluteCount >= 1_000 { return String(format: "%.1fK", absoluteCount / 1_000) }
        return "\(tokenCount)"
    }

    /// $0.00, <$0.01, $1.24, $1,240.
    static func dollars(_ amountInDollars: Double) -> String {
        if amountInDollars > 0 && amountInDollars < 0.01 { return "<$0.01" }
        if amountInDollars >= 1_000 {
            return "$" + amountInDollars.formatted(.number.precision(.fractionLength(0)))
        }
        return "$" + amountInDollars.formatted(.number.precision(.fractionLength(2)))
    }

    /// "17 Nov 2026" from "2026-11-17", or the text as it is.
    static func priceListDate(_ pricesAsOf: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let priceListDate = parser.date(from: pricesAsOf) else { return pricesAsOf }
        return priceListDate.formatted(date: .abbreviated, time: .omitted)
    }
}

struct LanguageModelUsageSettingsSection: View {
    @ObservedObject var usageLedger: LanguageModelUsageLedger
    @AppStorage("languageModelUsageSelectedPeriod") private var selectedPeriodRawValue = LanguageModelUsagePeriod.lastThirtyDays.rawValue
    @State private var userPricesByModelKey = LanguageModelUserPrices.all()
    @State private var modelBeingPriced: LanguageModelUsageSummary.ModelRow?
    @State private var isConfirmingReset = false

    /// On Settings › General the title is the section's heading.
    @Environment(\.usesSettingsListStyle) private var usesSettingsListStyle

    private var selectedPeriod: LanguageModelUsagePeriod {
        LanguageModelUsagePeriod(rawValue: selectedPeriodRawValue) ?? .lastThirtyDays
    }

    var body: some View {
        let summary = usageLedger.summary(for: selectedPeriod, userPricesByModelKey: userPricesByModelKey)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                SettingsRowIcon(systemName: "chart.bar")
                Text("Usage and cost")
                    .font(usesSettingsListStyle ? DS.Typography.headingSmall : DS.Typography.interface(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 8)
                Picker("Period", selection: $selectedPeriodRawValue) {
                    ForEach(LanguageModelUsagePeriod.allCases) { period in
                        Text(period.displayName).tag(period.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .pointerCursor()
            }

            if summary.totals.requests == 0 {
                Text("No model requests in this period yet.")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                LanguageModelUsageHeadlineNumbers(summary: summary)
                LanguageModelUsageTokenBreakdown(totals: summary.totals)

                LanguageModelUsageGroupHeader(title: "By model")
                VStack(spacing: 6) {
                    ForEach(summary.models) { modelRow in
                        LanguageModelUsageModelRowView(
                            modelRow: modelRow,
                            userPrices: userPricesByModelKey[modelRow.modelKey],
                            onSetPrice: { modelBeingPriced = modelRow }
                        )
                    }
                }

                LanguageModelUsageGroupHeader(title: "By kind of work")
                VStack(spacing: 6) {
                    ForEach(summary.categories, id: \.category) { categoryTotals in
                        LanguageModelUsageCategoryRowView(category: categoryTotals.category, totals: categoryTotals.totals)
                    }
                }
            }

            Text(footnoteText(for: summary))
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset usage…") { isConfirmingReset = true }
                    .disabled(usageLedger.entries.isEmpty)
                    .pointerCursor(isEnabled: !usageLedger.entries.isEmpty)
                Spacer()
            }
        }
        .sheet(item: $modelBeingPriced) { modelRow in
            LanguageModelPriceEditorSheet(
                modelRow: modelRow,
                existingPrices: userPricesByModelKey[modelRow.modelKey],
                onSave: { newPrices in
                    LanguageModelUserPrices.setPrices(newPrices, forModelKey: modelRow.modelKey)
                    userPricesByModelKey = LanguageModelUserPrices.all()
                    modelBeingPriced = nil
                },
                onCancel: { modelBeingPriced = nil }
            )
        }
        .confirmationDialog("Reset usage?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset usage", role: .destructive) { usageLedger.resetUsage() }
        } message: {
            Text("This clears every token count and cost elfhub has recorded on this Mac. Prices you set for models stay.")
        }
    }

    private func footnoteText(for summary: LanguageModelUsageSummary) -> String {
        var footnoteParts = [
            "An estimate from published prices (as of \(LanguageModelUsageFormatting.priceListDate(usageLedger.pricesAsOf))); your provider's bill is the source of truth.",
        ]
        if summary.unpricedTokens > 0 {
            footnoteParts.append("\(LanguageModelUsageFormatting.compactTokenCount(summary.unpricedTokens)) tokens from models without a price aren't in the cost.")
        }
        if summary.totals.requestsWithoutTokenCounts > 0 {
            footnoteParts.append("\(summary.totals.requestsWithoutTokenCounts) requests didn't report their tokens.")
        }
        footnoteParts.append("Only counts are kept, on this Mac.")
        return footnoteParts.joined(separator: " ")
    }
}

private struct LanguageModelUsageHeadlineNumbers: View {
    let summary: LanguageModelUsageSummary

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            headlineNumber(title: "Estimated cost", value: LanguageModelUsageFormatting.dollars(summary.totals.costInDollars))
            headlineNumber(title: "Tokens", value: LanguageModelUsageFormatting.compactTokenCount(summary.totals.totalTokens))
            headlineNumber(title: "Requests", value: summary.totals.requests.formatted())
            Spacer(minLength: 0)
        }
    }

    private func headlineNumber(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(DS.Typography.interface(size: 22, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .monospacedDigit()
            Text(title)
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

private struct LanguageModelUsageTokenBreakdown: View {
    let totals: LanguageModelUsageTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(breakdownText)
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .monospacedDigit()
            if let cachedInputShare = totals.cachedInputShare {
                // How much of the input was re-read from the prompt cache:
                // the higher, the cheaper long chats and screen runs are.
                Text("\(Int((cachedInputShare * 100).rounded()))% of input was read from the prompt cache")
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var breakdownText: String {
        var parts = [
            "New input \(LanguageModelUsageFormatting.compactTokenCount(totals.inputTokens))",
            "cached input \(LanguageModelUsageFormatting.compactTokenCount(totals.cacheReadTokens))",
        ]
        if totals.cacheWriteTokens > 0 {
            parts.append("cache writes \(LanguageModelUsageFormatting.compactTokenCount(totals.cacheWriteTokens))")
        }
        parts.append("output \(LanguageModelUsageFormatting.compactTokenCount(totals.outputTokens))")
        if totals.webSearches > 0 {
            parts.append("\(totals.webSearches) web searches")
        }
        return parts.joined(separator: " · ")
    }
}

private struct LanguageModelUsageGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .dsLabelStyle()
            .padding(.top, 2)
    }
}

private struct LanguageModelUsageModelRowView: View {
    let modelRow: LanguageModelUsageSummary.ModelRow
    let userPrices: LanguageModelTokenPrices?
    let onSetPrice: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(modelRow.modelName)
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(modelRow.providerName)
                    .font(DS.Typography.interface(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(LanguageModelUsageFormatting.compactTokenCount(modelRow.totals.totalTokens)) tokens")
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .monospacedDigit()
            costView
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var costView: some View {
        switch modelRow.pricingSource {
        case .onThisMac:
            costCaption("Free · on this Mac")
        case .chatGPTPlan:
            costCaption("In your ChatGPT plan")
        case .unknown where modelRow.hasUnpricedRequests:
            Button("Set price…", action: onSetPrice)
                .buttonStyle(.plain)
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
                .help("This model isn't in elfhub's price list. Give it a price to include it in the cost.")
        case .unknown:
            Button(action: onSetPrice) {
                Text(LanguageModelUsageFormatting.dollars(modelRow.totals.costInDollars))
                    .font(DS.Typography.interface(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Priced with the price you set. Click to change it.")
        case .priceList, .reportedByProvider:
            Text(LanguageModelUsageFormatting.dollars(modelRow.totals.costInDollars))
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .monospacedDigit()
                .help(modelRow.pricingSource == .reportedByProvider ? "What the provider said it charged." : "From elfhub's price list.")
        }
    }

    private func costCaption(_ captionText: String) -> some View {
        Text(captionText)
            .font(DS.Typography.interface(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
    }
}

private struct LanguageModelUsageCategoryRowView: View {
    let category: LanguageModelUsageCategory
    let totals: LanguageModelUsageTotals

    var body: some View {
        HStack(spacing: 10) {
            Text(category.displayName)
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 8)
            Text(totals.requests == 1 ? "1 request" : "\(totals.requests.formatted()) requests")
                .font(DS.Typography.interface(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .monospacedDigit()
            Text("\(LanguageModelUsageFormatting.compactTokenCount(totals.totalTokens)) tokens")
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .monospacedDigit()
            Text(LanguageModelUsageFormatting.dollars(totals.costInDollars))
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .monospacedDigit()
                .frame(minWidth: 96, alignment: .trailing)
        }
    }
}

/// Giving a model the price list doesn't have a price, per million tokens.
private struct LanguageModelPriceEditorSheet: View {
    let modelRow: LanguageModelUsageSummary.ModelRow
    let existingPrices: LanguageModelTokenPrices?
    let onSave: (LanguageModelTokenPrices?) -> Void
    let onCancel: () -> Void

    @State private var inputPriceText = ""
    @State private var cachedInputPriceText = ""
    @State private var outputPriceText = ""

    private var enteredPrices: LanguageModelTokenPrices? {
        guard let inputPrice = Self.price(from: inputPriceText), let outputPrice = Self.price(from: outputPriceText) else { return nil }
        return LanguageModelTokenPrices(input: inputPrice, output: outputPrice, cacheWrite: nil, cacheRead: Self.price(from: cachedInputPriceText))
    }

    private static func price(from priceText: String) -> Double? {
        let cleanedText = priceText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
        guard let price = Double(cleanedText), price >= 0 else { return nil }
        return price
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Price for \(modelRow.modelName)")
                    .font(DS.Typography.headingSmall)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("From \(modelRow.providerName)'s pricing page, in US dollars per million tokens. Used for this model's usage, past and future.")
                    .font(DS.Typography.interface(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            priceField(title: "Input", text: $inputPriceText)
            priceField(title: "Cached input (optional)", text: $cachedInputPriceText)
            priceField(title: "Output", text: $outputPriceText)
            HStack {
                if existingPrices != nil {
                    Button("Remove price") { onSave(nil) }
                        .pointerCursor()
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button("Save") { onSave(enteredPrices) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(enteredPrices == nil)
                    .pointerCursor(isEnabled: enteredPrices != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let existingPrices {
                inputPriceText = String(existingPrices.input)
                outputPriceText = String(existingPrices.output)
                cachedInputPriceText = existingPrices.cacheRead.map { String($0) } ?? ""
            }
        }
    }

    private func priceField(title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(DS.Typography.interface(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            TextField("$ per 1M", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .multilineTextAlignment(.trailing)
        }
    }
}
