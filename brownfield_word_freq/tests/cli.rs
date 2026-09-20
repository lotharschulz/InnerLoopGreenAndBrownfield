use std::env;
use std::fs;
use std::path::PathBuf;
use std::process;
use std::process::Command;

const BINARY: &str = env!("CARGO_BIN_EXE_brownfield_word_freq");

// Tests run in parallel, so the temp filename carries the pid and a per-test label.
fn write_temp_file(label: &str, contents: &str) -> PathBuf {
    let path = env::temp_dir().join(format!(
        "{}-{}-{label}.txt",
        env!("CARGO_PKG_NAME"),
        process::id()
    ));
    fs::write(&path, contents).expect("could not write temp file");
    path
}

#[test]
fn prints_top_words_for_file_argument() {
    let path = write_temp_file("argument", "the quick brown fox the lazy dog the fox\n");
    let output = Command::new(BINARY)
        .arg(&path)
        .output()
        .expect("could not run binary");
    fs::remove_file(&path).ok();

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).expect("stdout was not utf-8");
    let mut lines = stdout.lines();
    assert_eq!(lines.next(), Some("Top 10 words:"));

    // Compare on split columns rather than the padded literal: the column width is
    // cosmetic, the ranking (including the alphabetical tie-break) is the behavior.
    let ranked: Vec<(&str, &str)> = lines
        .map(|line| {
            let mut parts = line.split_whitespace();
            (
                parts.next().expect("missing word"),
                parts.next().expect("missing count"),
            )
        })
        .collect();
    assert_eq!(
        ranked,
        vec![
            ("the", "3"),
            ("fox", "2"),
            ("brown", "1"),
            ("dog", "1"),
            ("lazy", "1"),
            ("quick", "1")
        ]
    );
}

#[test]
fn reads_default_input_txt_when_no_argument() {
    let output = Command::new(BINARY)
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("could not run binary");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).expect("stdout was not utf-8");
    assert_eq!(stdout.lines().next(), Some("Top 10 words:"));
    assert!(stdout.lines().count() > 1, "no word rows printed");
}

#[test]
fn reports_missing_file() {
    let output = Command::new(BINARY)
        .arg("definitely-not-a-real-file.txt")
        .output()
        .expect("could not run binary");

    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).expect("stderr was not utf-8");
    assert!(
        stderr.contains("Could not read file"),
        "stderr was: {stderr}"
    );
}
