import SwiftUI

/// 搜索 Tab：大搜索框 + 结果网格 + 空态引导。检索逻辑在 SearchResultsGrid / SemanticSearch。
struct SearchTabView: View {
    @State private var searchText = ""

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.muted)
                TextField("描述照片：猫 / 风景 / 发票号 / http…", text: $searchText)
                    .font(.title3)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("searchField")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: 52)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .padding(Theme.Spacing.md)

            if trimmedQuery.isEmpty {
                Spacer()
                Theme.EmptyState(
                    systemImage: "text.magnifyingglass",
                    title: "用自然语言找照片",
                    hint: "语义搜索理解内容（「海边的日落」），也会匹配照片里的文字（发票号、快递单号、网址）。\n先回「清理」Tab 建立索引后即可搜索。"
                )
                Spacer()
            } else {
                SearchResultsGrid(query: searchText)
            }
        }
        .background(Theme.background)
        .navigationTitle("搜索")
    }
}
