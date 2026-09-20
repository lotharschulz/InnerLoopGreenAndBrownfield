use std::collections::HashMap;
use std::env;
use std::fs;

const TOP_N: usize = 10;

/// Lowercase a word and strip everything non-alphanumeric.
/// Returns None when nothing alphanumeric remains.
fn normalize(word: &str) -> Option<String> {
    let cleaned: String = word
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase();

    if cleaned.is_empty() {
        return None;
    }

    Some(cleaned)
}

fn count_words(contents: &str) -> HashMap<String, u32> {
    let mut counts: HashMap<String, u32> = HashMap::new();

    for word in contents.split_whitespace() {
        if let Some(cleaned) = normalize(word) {
            *counts.entry(cleaned).or_insert(0) += 1;
        }
    }

    counts
}

/// Ties break alphabetically: HashMap iteration order is randomized, so ordering on the
/// count alone puts equal-count words in a different order on every run.
fn top_n(counts: &HashMap<String, u32>, limit: usize) -> Vec<(&str, u32)> {
    let mut ranked: Vec<(&str, u32)> = counts
        .iter()
        .map(|(word, count)| (word.as_str(), *count))
        .collect();

    ranked.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    ranked.truncate(limit);
    ranked
}

fn main() {
    // Get filename from command line, or use a default
    let args: Vec<String> = env::args().collect();
    let filename = args.get(1).map(|s| s.as_str()).unwrap_or("input.txt");

    let contents = fs::read_to_string(filename).expect("Could not read file");

    println!("Top {TOP_N} words:");
    for (word, count) in top_n(&count_words(&contents), TOP_N) {
        println!("{word:<15} {count}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counts_from(pairs: &[(&str, u32)]) -> HashMap<String, u32> {
        pairs
            .iter()
            .map(|(word, count)| (word.to_string(), *count))
            .collect()
    }

    fn sorted_pairs(counts: &HashMap<String, u32>) -> Vec<(&str, u32)> {
        let mut pairs: Vec<(&str, u32)> = counts
            .iter()
            .map(|(word, count)| (word.as_str(), *count))
            .collect();
        pairs.sort();
        pairs
    }

    #[test]
    fn lowercases_mixed_case_word() {
        assert_eq!(normalize("The").as_deref(), Some("the"));
    }

    #[test]
    fn strips_trailing_punctuation() {
        assert_eq!(normalize("fox.").as_deref(), Some("fox"));
    }

    #[test]
    fn returns_none_for_punctuation_only() {
        assert_eq!(normalize("---"), None);
    }

    #[test]
    fn joins_letters_around_apostrophe() {
        assert_eq!(normalize("Don't").as_deref(), Some("dont"));
    }

    #[test]
    fn keeps_digits() {
        assert_eq!(normalize("42").as_deref(), Some("42"));
    }

    #[test]
    fn keeps_non_ascii_alphanumeric() {
        assert_eq!(normalize("Ärger").as_deref(), Some("ärger"));
    }

    #[test]
    fn returns_empty_map_for_empty_input() {
        assert!(count_words("").is_empty());
    }

    #[test]
    fn returns_empty_map_for_whitespace_only() {
        assert!(count_words(" \t\n ").is_empty());
    }

    #[test]
    fn counts_each_occurrence_of_repeated_word() {
        assert_eq!(
            sorted_pairs(&count_words("the quick brown fox the lazy dog the fox")),
            vec![
                ("brown", 1),
                ("dog", 1),
                ("fox", 2),
                ("lazy", 1),
                ("quick", 1),
                ("the", 3)
            ]
        );
    }

    #[test]
    fn folds_case_variants_into_one_entry() {
        assert_eq!(sorted_pairs(&count_words("The the THE")), vec![("the", 3)]);
    }

    #[test]
    fn splits_on_tabs_and_newlines() {
        assert_eq!(
            sorted_pairs(&count_words("alpha\tbeta\ngamma")),
            vec![("alpha", 1), ("beta", 1), ("gamma", 1)]
        );
    }

    #[test]
    fn orders_by_descending_count() {
        let counts = counts_from(&[("rare", 1), ("common", 9), ("mid", 4)]);
        assert_eq!(
            top_n(&counts, 3),
            vec![("common", 9), ("mid", 4), ("rare", 1)]
        );
    }

    #[test]
    fn breaks_count_ties_alphabetically() {
        // Six tied words: under the unsorted-tie bug this exact order comes up by chance
        // in 1 run out of 720, so the test reliably catches a regression.
        let counts = counts_from(&[
            ("fig", 2),
            ("date", 2),
            ("banana", 2),
            ("elder", 2),
            ("apple", 2),
            ("cherry", 2),
        ]);
        assert_eq!(
            top_n(&counts, 6),
            vec![
                ("apple", 2),
                ("banana", 2),
                ("cherry", 2),
                ("date", 2),
                ("elder", 2),
                ("fig", 2)
            ]
        );
    }

    #[test]
    fn returns_all_words_when_fewer_than_limit() {
        let counts = counts_from(&[("alpha", 1), ("beta", 2)]);
        assert_eq!(top_n(&counts, TOP_N).len(), 2);
    }

    #[test]
    fn truncates_to_limit_when_more_words_than_limit() {
        let counts: HashMap<String, u32> = (0..15u32).map(|i| (format!("word{i:02}"), i)).collect();
        assert_eq!(top_n(&counts, TOP_N).len(), TOP_N);
    }

    #[test]
    fn returns_empty_for_zero_limit() {
        let counts = counts_from(&[("alpha", 1)]);
        assert!(top_n(&counts, 0).is_empty());
    }
}
