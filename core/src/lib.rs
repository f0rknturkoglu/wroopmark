//! wroopmark core: everything below the UI.
//!
//! - [`model`]   the one normalized shape every saved post is stored in
//! - [`text`]    Turkish-aware search folding, URL normalization and ids
//! - [`query`]   search syntax (`tag:dev from:@jack has:image "phrase"`)
//! - [`db`]      SQLite + FTS5 library
//! - [`media`]   content-addressed media files
//! - [`x`]       X/Twitter GraphQL timeline parser (fed by the extensions)
//! - [`tiktok`]  TikTok item parser (video pages and web API responses)
//! - [`reddit`]  Reddit listing parser (saved posts and comments)
//! - [`instagram`] Instagram media parser (the Saved page's API responses)
//! - [`fetch`]   network capture for plain URLs (oEmbed, OpenGraph)
//! - [`archive`] bulk imports: bookmarks.html, platform data downloads, CSV
//! - [`localfile`] pictures and videos from disk
//! - [`export`]  Markdown (Obsidian) and CSV export
//! - [`ai`]      on-device vectors and summaries via the `wroopmark-ai` helper
//! - [`mcp`]     Model Context Protocol server for agents (`wroopmark mcp`)
//! - [`api`]     JSON command surface shared by FFI, CLI and native host
//! - [`ffi`]     C ABI for Swift

pub mod ai;
pub mod api;
pub mod archive;
pub mod bluesky;
pub mod db;
pub mod export;
pub mod external;
pub mod fetch;
pub mod ffi;
pub mod instagram;
pub mod localfile;
pub mod mcp;
pub mod media;
pub mod model;
pub mod query;
pub mod reddit;
pub mod text;
pub mod tiktok;
pub mod x;
pub mod youtube;

pub use api::Library;
