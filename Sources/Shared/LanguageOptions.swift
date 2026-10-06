import SwiftUI

/// A language picker's choices: the likeliest few, then every other language
/// alphabetically, so the one wanted is usually at the top rather than among eighty.
struct LanguageOptions: View {
    /// Language codes, likeliest first.
    let suggested: [String]

    var body: some View {
        ForEach(suggested, id: \.self) { code in
            Text(Languages.name(code)).tag(code)
        }
        if !suggested.isEmpty { Divider() }
        ForEach(Languages.sortedTargets.filter { !suggested.contains($0) }, id: \.self) { code in
            Text(Languages.name(code)).tag(code)
        }
    }
}
