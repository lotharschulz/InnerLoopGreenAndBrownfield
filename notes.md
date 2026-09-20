```zsh
rustc --version
cargo --version
# If not installed, get it via rustup.rs:
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

# Greenfield setup

```zsh
#!/bin/bash
set -e

cargo new greenfield_word_freq
cd greenfield_word_freq
touch src/main.rs

cat > src/main.rs << 'EOF'
use std::collections::HashMap;
use std::env;
use std::fs;

fn main() {
    // Get filename from command line, or use a default
    let args: Vec<String> = env::args().collect();
    let filename = args.get(1).map(|s| s.as_str()).unwrap_or("input.txt");

    // Read the file into a String
    let contents = fs::read_to_string(filename)
        .expect("Could not read file");

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
EOF

echo "the quick brown fox the lazy dog the fox" > input.txt

# build and run
cargo run

# build and run with input file flag
cargo run -- input.txt

# Build a release binary (optimized, for actual use/distribution)
cargo build --release
./target/release/greenfield_word_freq input.txt
```

# Brownfield setup

```zsh
#!/bin/bash
set -e

cargo new brownfield_word_freq
cd brownfield_word_freq
touch src/main.rs

cat > src/main.rs << 'EOF'
use std::collections::HashMap;
use std::env;
use std::fs;

fn main() {
    // Get filename from command line, or use a default
    let args: Vec<String> = env::args().collect();
    let filename = args.get(1).map(|s| s.as_str()).unwrap_or("input.txt");

    // Read the file into a String
    let contents = fs::read_to_string(filename)
        .expect("Could not read file");

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
EOF

echo "the quick brown fox the lazy dog the fox" > input.txt

# build and run
cargo run

# build and run with input file flag
cargo run -- input.txt

# Build a release binary (optimized, for actual use/distribution)
cargo build --release
./target/release/brownfield_word_freq input.txt
```

# Pre-commit hook

One-time per clone (`.githooks/pre-commit` is tracked; `core.hooksPath` is local git
config and is not):

```zsh
git config core.hooksPath .githooks
```

Blocks the commit unless `cargo test --manifest-path Cargo.toml && cargo fmt --all --
--check && cargo clippy` passes in both `brownfield_word_freq/` and
`greenfield_word_freq/`. Bypass (not recommended): `git commit --no-verify`.

```zsh
cd brownfield_word_freq && cargo test --manifest-path Cargo.toml && cargo fmt --all -- --check && cargo clippy && cd ../greenfield_word_freq && cargo test --manifest-path Cargo.toml && cargo fmt --all -- --check && cargo clippy && cd ..
```
