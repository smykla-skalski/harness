//! Wire types shared with the Harness Monitor `AccessibilityRegistry`.
//!
//! Mirrors `mcp-servers/harness-monitor/src/protocol.ts`: one request per
//! line, one response per line, each with a monotonic `id` that the
//! response echoes.

use serde::de::Error as _;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ElementKind {
    Button,
    Toggle,
    TextField,
    Text,
    Link,
    List,
    Row,
    Tab,
    MenuItem,
    Image,
    Other,
}

impl ElementKind {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Button => "button",
            Self::Toggle => "toggle",
            Self::TextField => "textField",
            Self::Text => "text",
            Self::Link => "link",
            Self::List => "list",
            Self::Row => "row",
            Self::Tab => "tab",
            Self::MenuItem => "menuItem",
            Self::Image => "image",
            Self::Other => "other",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryElement {
    pub identifier: String,
    pub label: Option<String>,
    pub value: Option<String>,
    pub hint: Option<String>,
    pub kind: ElementKind,
    pub frame: Rect,
    #[serde(rename = "windowID")]
    pub window_id: Option<i64>,
    pub enabled: bool,
    pub selected: bool,
    pub focused: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryWindow {
    pub id: i64,
    pub title: String,
    pub role: Option<String>,
    pub frame: Rect,
    #[serde(rename = "isKey")]
    pub is_key: bool,
    #[serde(rename = "isMain")]
    pub is_main: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum RegistryRequest {
    Ping {
        id: u64,
    },
    ListWindows {
        id: u64,
    },
    ListElements {
        id: u64,
        #[serde(rename = "windowID", skip_serializing_if = "Option::is_none")]
        window_id: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        kind: Option<ElementKind>,
    },
    GetElement {
        id: u64,
        identifier: String,
    },
}

impl RegistryRequest {
    #[must_use]
    pub fn id(&self) -> u64 {
        match self {
            Self::Ping { id }
            | Self::ListWindows { id }
            | Self::ListElements { id, .. }
            | Self::GetElement { id, .. } => *id,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct RegistryResponse {
    pub id: u64,
    #[serde(flatten)]
    pub outcome: RegistryOutcome,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum RegistryOutcome {
    Ok {
        ok: OkMarker,
        result: serde_json::Value,
    },
    Err {
        ok: ErrMarker,
        error: RegistryErrorBody,
    },
}

#[derive(Debug, Clone, Deserialize)]
pub struct RegistryErrorBody {
    pub code: String,
    pub message: String,
}

/// Zero-sized marker that only deserializes from `true`.
#[derive(Debug, Clone)]
pub struct OkMarker;

impl<'de> Deserialize<'de> for OkMarker {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        if bool::deserialize(deserializer)? {
            Ok(Self)
        } else {
            Err(D::Error::custom("expected ok: true"))
        }
    }
}

/// Zero-sized marker that only deserializes from `false`.
#[derive(Debug, Clone)]
pub struct ErrMarker;

impl<'de> Deserialize<'de> for ErrMarker {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        if bool::deserialize(deserializer)? {
            Err(D::Error::custom("expected ok: false"))
        } else {
            Ok(Self)
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListWindowsResult {
    pub windows: Vec<RegistryWindow>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListElementsResult {
    pub elements: Vec<RegistryElement>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GetElementResult {
    pub element: RegistryElement,
}
