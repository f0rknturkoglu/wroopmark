//! wroopmark core: everything below the UI.
//!
//! - [`model`]   the one normalized shape every saved post is stored in
//! - [`text`]    Turkish-aware search folding, URL normalization and ids
//! - [`query`]   search syntax (`tag:dev from:@jack has:image "phrase"`)
//! - [`db`]      SQLite + FTS5 library
//! - [`media`]   content-addressed media files
//! - [`x`]       X/Twitter GraphQL timeline parser (fed by the extensions)
//! - [`tiktok`]  TikTok item parser (video pages and web API responses)
//! - [`fetch`]   network capture for plain URLs (oEmbed, OpenGraph)
//! - [`api`]     JSON command surface shared by FFI, CLI and native host
//! - [`ffi`]     C ABI for Swift

pub mod api;
pub mod db;
pub mod external;
pub mod fetch;
pub mod ffi;
pub mod media;
pub mod model;
pub mod query;
pub mod text;
pub mod tiktok;
pub mod x;

pub use api::Library;
