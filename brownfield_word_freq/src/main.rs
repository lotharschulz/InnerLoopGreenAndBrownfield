use std::collections::HashMap;
use std::env;
use std::fs;

fn main() {
    // Get filename from command line, or use a default
    let args: Vec<String> = env::args().collect();
    let filename = args.get(1).map(|s| s.as_str()).unwrap_or("input.txt");

    // Read the file into a String
    let contents = fs::read_to_string(filename).expect("Could not read file");

    // Count word frequencies
    let mut counts: HashMap<String, u32> = HashMap::new();

    for word in contents.split_whitespace() {
        // Normalize: lowercase and strip punctuation
        let cleaned: String = word
            .chars()
            .filter(|c| c.is_alphanumeric())
            .collect::<String>()
            .to_lowercase();

        if cleaned.is_empty() {
            continue;
        }

        *counts.entry(cleaned).or_insert(0) += 1;
    }

    // Convert to a vector so we can sort by count
    let mut count_vec: Vec<(&String, &u32)> = counts.iter().collect();
    count_vec.sort_by(|a, b| b.1.cmp(a.1)); // descending by count

    // Print the top 10
    println!("Top 10 words:");
    for (word, count) in count_vec.iter().take(10) {
        println!("{:<15} {}", word, count);
    }
}
