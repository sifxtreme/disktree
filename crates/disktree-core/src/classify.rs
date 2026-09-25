//! What a directory *is*, and whether its space can be had back.
//!
//! Colour in the treemap means a kind of data, and a hatch means reclaimable
//! space, so the two questions a cleanup tool exists to answer — "what is it"
//! and "can I delete it" — can be read off a tile at a glance.
//!
//! Both come from names. A short lookup of well-known directory names covers
//! most of a home directory; anything unmatched takes its parent's kind, and a
//! top-level directory with an unknown name takes the kind of its largest
//! recognisable child (`~/world` is mostly `.git`, so it is git). Reclaimable
//! space is the same idea, plus a sibling check where a name alone is too
//! common to trust: `target` is only a build directory beside a `Cargo.toml`.

use crate::tree::Node;

/// A kind of data, for colour.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Category {
    /// Source code and checkouts.
    Code,
    /// Space agents write into: worktrees, sandboxes, experiments.
    AgentScratch,
    /// Compilers, package managers and their installs.
    Toolchain,
    /// Folders a sync client owns.
    Synced,
    /// Version-control object stores.
    Git,
    /// Pictures, music, video, games and models.
    Media,
    /// Documents, downloads and the desktop.
    Documents,
    /// Caches and other regenerable state.
    Cache,
    /// Nothing recognisable.
    #[default]
    Other,
}

impl Category {
    /// The categories the legend lists, in its order.
    pub const LEGEND: [Self; 8] = [
        Self::Code,
        Self::AgentScratch,
        Self::Toolchain,
        Self::Synced,
        Self::Git,
        Self::Media,
        Self::Documents,
        Self::Cache,
    ];

    pub const fn label(self) -> &'static str {
        match self {
            Self::Code => "Code",
            Self::AgentScratch => "Agent scratch",
            Self::Toolchain => "Toolchains",
            Self::Synced => "Synced",
            Self::Git => "Git",
            Self::Media => "Media",
            Self::Documents => "Documents",
            Self::Cache => "Cache",
            Self::Other => "Other",
        }
    }
}

/// Why a directory's space can be had back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Reclaim {
    /// A cache: whatever wrote it will write it again.
    Regenerable,
    /// A sync client's old versions of files.
    SyncHistory,
    /// A package manager's content store.
    PackageStore,
    /// Compiler or bundler output beside its sources.
    BuildOutput,
    /// Installed dependencies beside their manifest.
    Reinstallable,
    /// Container or sandbox image layers.
    SandboxLayers,
    /// Sandbox or VM snapshots.
    Snapshots,
    /// Already deleted, still on disk.
    Trash,
    /// Scratch space meant to be thrown away.
    Temporary,
}

impl Reclaim {
    /// The reason, as the "Worth a look" list says it.
    pub const fn label(self) -> &'static str {
        match self {
            Self::Regenerable => "regenerable",
            Self::SyncHistory => "sync history",
            Self::PackageStore => "package store",
            Self::BuildOutput => "build output",
            Self::Reinstallable => "reinstallable",
            Self::SandboxLayers => "sandbox layers",
            Self::Snapshots => "snapshots",
            Self::Trash => "trash",
            Self::Temporary => "temporary",
        }
    }
}

/// Files whose names classification reads beside a directory (`target` next to `Cargo.toml`,
/// `node_modules` next to `package.json`, a git store's `HEAD`). A scan that folds small files must
/// keep these, or build output and dependencies stop being recognised.
pub const MARKER_FILES: &[&str] = &["Cargo.toml", "package.json", "HEAD"];

/// The kind a directory name announces on its own, if any.
pub fn category_of_name(name: &str) -> Option<Category> {
    let lower = name.to_ascii_lowercase();
    let category = match lower.as_str() {
        "src" | "code" | "projects" | "repos" | "dev" | "work"
        | "workspace" | "workspaces" | "github.com" | "gitlab.com"
        | "sites" | "development" => Category::Code,
        ".codex" | ".claude" | ".herdr" | ".pi" | ".cursor" | ".aider"
        | ".gemini" | ".continue" | ".windsurf" | ".microsandbox" | ".omp"
        | ".agents" | ".openai" | "tries" | "worktrees" | "experiments"
        | "scratch" | "playground" => Category::AgentScratch,
        ".cargo" | ".rustup" | ".local" | ".npm" | ".pnpm-store" | "pnpm"
        | ".bun" | ".deno" | "go" | ".gradle" | ".m2" | ".platformio"
        | "mise" | ".mise" | ".pyenv" | ".nvm" | ".gem" | "gem" | ".rbenv"
        | ".espressif" | ".arduino15" | ".config" | ".vscode" | ".zig"
        | ".rye" | ".conda" | "anaconda3" | "miniconda3" | ".opam"
        | ".ghcup" | ".stack" | ".julia" | ".dotnet" | ".android"
        | ".sdkman" | ".volta" | ".yarn" | ".java" => Category::Toolchain,
        "sync" | "dropbox" | "nextcloud" | "google drive" | "onedrive"
        | "pclouddrive" | "mega" | ".stversions" => Category::Synced,
        ".git" => Category::Git,
        "pictures" | "photos" | "music" | "videos" | "movies" | "steam"
        | "models" | ".ollama" | ".lmstudio" | "games" | "wineprefix" => {
            Category::Media
        }
        "documents" | "desktop" | "downloads" | "books" | "notes"
        | "obsidian" | "public" | "templates" => Category::Documents,
        ".cache" | "cache" | "caches" | ".ccache" | ".sccache" | "_cacache"
        | "__pycache__" | "node_modules" | "trash" | ".trash" | "tmp"
        | ".tmp" => Category::Cache,
        _ => return None,
    };
    Some(category)
}

/// Whether a directory's space can be had back, judged from its name, the
/// kind of the directory holding it, and its siblings' names.
pub fn reclaim_of(
    name: &str,
    parent: Category,
    has_sibling: impl Fn(&str) -> bool,
) -> Option<Reclaim> {
    let lower = name.to_ascii_lowercase();
    let reclaim = match lower.as_str() {
        ".cache" | "cache" | "caches" | ".ccache" | ".sccache" | "_cacache" => {
            Reclaim::Regenerable
        }
        ".stversions" => Reclaim::SyncHistory,
        ".pnpm-store" | "pnpm" => Reclaim::PackageStore,
        "__pycache__" | ".pytest_cache" | ".mypy_cache" | ".ruff_cache"
        | ".next" | ".turbo" | ".parcel-cache" => Reclaim::BuildOutput,
        // Too common to trust alone: only a build directory beside a manifest.
        "target" if has_sibling("Cargo.toml") => Reclaim::BuildOutput,
        "node_modules" if has_sibling("package.json") => Reclaim::Reinstallable,
        // Layers and snapshots are only disposable inside sandbox state.
        "layers" if parent == Category::AgentScratch => Reclaim::SandboxLayers,
        "snapshots" if parent == Category::AgentScratch => Reclaim::Snapshots,
        "trash" | ".trash" => Reclaim::Trash,
        "tmp" | ".tmp" => Reclaim::Temporary,
        _ => return None,
    };
    Some(reclaim)
}

/// Assign a category and a reclaim reason to every node beneath `root`.
///
/// Top-down: a node's own name wins, otherwise it inherits. Reclaimable
/// space is inherited too, so everything under a cache is hatched.
pub fn classify(root: &mut Node) {
    root.category = Category::Other;
    root.reclaim = None;
    let children = std::mem::take(&mut root.children);
    let names: Vec<Box<str>> =
        children.iter().map(|child| child.name.clone()).collect();
    root.children = children;
    for index in 0..root.children.len() {
        let has_sibling =
            |wanted: &str| names.iter().any(|name| &**name == wanted);
        let child = &mut root.children[index];
        // A top-level directory with an unknown name takes the kind of its
        // largest recognisable child: `~/world` is mostly `.git`.
        let category = category_of_name(&child.name)
            .or_else(|| is_git_store(child).then_some(Category::Git))
            .or_else(|| dominant_child_category(child))
            .unwrap_or(Category::Other);
        let reclaim = child
            .is_dir()
            .then(|| reclaim_of(&child.name, Category::Other, has_sibling))
            .flatten();
        classify_below(child, category, reclaim);
    }
}

fn classify_below(
    node: &mut Node,
    category: Category,
    reclaim: Option<Reclaim>,
) {
    node.category = category;
    node.reclaim = reclaim;
    if node.children.is_empty() {
        return;
    }
    let names: Vec<Box<str>> = node
        .children
        .iter()
        .map(|child| child.name.clone())
        .collect();
    for child in &mut node.children {
        let has_sibling =
            |wanted: &str| names.iter().any(|name| &**name == wanted);
        let child_category = if child.is_dir() {
            category_of_name(&child.name)
                .or_else(|| is_git_store(child).then_some(Category::Git))
                .unwrap_or(category)
        } else {
            category
        };
        let child_reclaim = reclaim.or_else(|| {
            child
                .is_dir()
                .then(|| reclaim_of(&child.name, category, has_sibling))
                .flatten()
        });
        classify_below(child, child_category, child_reclaim);
    }
}

/// The kind of an unknown directory, from what fills it: the first
/// recognisable name down the largest children, a few levels deep.
fn dominant_child_category(node: &Node) -> Option<Category> {
    let mut node = node;
    for _ in 0..3 {
        if let Some(category) = node
            .children
            .iter()
            .filter(|child| child.is_dir())
            .find_map(|child| {
                category_of_name(&child.name)
                    .or_else(|| is_git_store(child).then_some(Category::Git))
            })
        {
            return Some(category);
        }
        node = node.children.iter().find(|child| child.is_dir())?;
    }
    None
}

/// A git object store by its shape, whatever it is called: a bare
/// repository, or a `.git` directory, has `objects`, `refs` and `HEAD`.
pub fn is_git_store(node: &Node) -> bool {
    let has =
        |wanted: &str| node.children.iter().any(|child| &*child.name == wanted);
    node.is_dir() && has("objects") && has("refs") && has("HEAD")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::{Metric, NodeKind, aggregate};

    fn file(name: &str, bytes: u64) -> Node {
        Node::entry(name, NodeKind::File, bytes)
    }

    fn dir(name: &str, children: Vec<Node>) -> Node {
        let mut node = Node::directory(name);
        node.children = children;
        node
    }

    fn home() -> Node {
        let mut home = dir(
            "tobi",
            vec![
                dir(
                    "src",
                    vec![dir(
                        "tries",
                        vec![dir("2026-09-01", vec![file("a", 1)])],
                    )],
                ),
                dir(
                    ".cache",
                    vec![dir("kache", vec![dir("store", vec![file("b", 1)])])],
                ),
                dir(
                    "world",
                    vec![
                        dir(".git", vec![dir("objects", vec![file("c", 9)])]),
                        file("README", 1),
                    ],
                ),
                dir(
                    "rust-thing",
                    vec![
                        file("Cargo.toml", 1),
                        dir("target", vec![file("d", 5)]),
                    ],
                ),
                dir("js-thing", vec![dir("target", vec![file("e", 5)])]),
                dir(
                    ".microsandbox",
                    vec![
                        dir("cache", vec![dir("layers", vec![file("f", 1)])]),
                        dir("snapshots", vec![file("g", 1)]),
                    ],
                ),
                dir("Sync", vec![dir(".stversions", vec![file("h", 1)])]),
                dir("mystery", vec![file("i", 1)]),
                dir(
                    "monorepo",
                    vec![dir(
                        "git",
                        vec![
                            file("HEAD", 1),
                            dir("refs", vec![]),
                            dir("objects", vec![file("pack", 50)]),
                        ],
                    )],
                ),
            ],
        );
        aggregate(&mut home, Metric::Bytes);
        classify(&mut home);
        home
    }

    fn named<'a>(node: &'a Node, path: &[&str]) -> &'a Node {
        let mut node = node;
        for part in path {
            node = node
                .children
                .iter()
                .find(|child| &*child.name == *part)
                .unwrap_or_else(|| panic!("no {part}"));
        }
        node
    }

    #[test]
    fn names_announce_their_kind_and_children_inherit_it() {
        let home = home();
        assert_eq!(named(&home, &["src"]).category, Category::Code);
        // `tries` is agent scratch even inside code: it is what agents write.
        assert_eq!(
            named(&home, &["src", "tries"]).category,
            Category::AgentScratch
        );
        assert_eq!(
            named(&home, &["src", "tries", "2026-09-01"]).category,
            Category::AgentScratch,
            "an unknown name inherits"
        );
        assert_eq!(
            named(&home, &["src", "tries", "2026-09-01", "a"]).category,
            Category::AgentScratch,
            "files inherit too"
        );
    }

    #[test]
    fn an_unknown_top_level_directory_takes_its_largest_known_child() {
        let home = home();
        assert_eq!(named(&home, &["world"]).category, Category::Git);
        assert_eq!(named(&home, &["mystery"]).category, Category::Other);
        // A bare repository is git by its shape, whatever it is called.
        assert_eq!(named(&home, &["monorepo"]).category, Category::Git);
        assert_eq!(named(&home, &["monorepo", "git"]).category, Category::Git);
    }

    #[test]
    fn caches_are_reclaimable_all_the_way_down() {
        let home = home();
        assert_eq!(
            named(&home, &[".cache"]).reclaim,
            Some(Reclaim::Regenerable)
        );
        assert_eq!(
            named(&home, &[".cache", "kache", "store"]).reclaim,
            Some(Reclaim::Regenerable)
        );
        assert_eq!(
            named(&home, &["Sync", ".stversions"]).reclaim,
            Some(Reclaim::SyncHistory)
        );
        assert_eq!(named(&home, &["src"]).reclaim, None);
    }

    #[test]
    fn target_is_build_output_only_beside_a_cargo_manifest() {
        let home = home();
        assert_eq!(
            named(&home, &["rust-thing", "target"]).reclaim,
            Some(Reclaim::BuildOutput)
        );
        assert_eq!(named(&home, &["js-thing", "target"]).reclaim, None);
    }

    #[test]
    fn sandbox_layers_and_snapshots_are_reclaimable_only_in_sandbox_state() {
        let home = home();
        // .microsandbox/cache is already a regenerable cache, so its layers
        // inherit that; the snapshots are judged on their own.
        assert!(
            named(&home, &[".microsandbox", "cache", "layers"])
                .reclaim
                .is_some()
        );
        assert_eq!(
            named(&home, &[".microsandbox", "snapshots"]).reclaim,
            Some(Reclaim::Snapshots)
        );
        assert_eq!(
            reclaim_of("snapshots", Category::Documents, |_| false),
            None
        );
    }

    #[test]
    fn the_legend_lists_every_named_category_once() {
        let mut seen = std::collections::HashSet::new();
        for category in Category::LEGEND {
            assert!(seen.insert(category));
            assert_ne!(category, Category::Other);
            assert!(!category.label().is_empty());
        }
    }
}
