use serde_json::{json, Value};
use std::fmt;

#[derive(Debug)]
pub struct ToolError {
    pub message: String,
    pub code: Option<String>,
}

impl ToolError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: None,
        }
    }

    pub fn code(message: impl Into<String>, code: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: Some(code.into()),
        }
    }

    pub fn payload(&self) -> Value {
        let mut value = json!({ "error": self.message });
        if let Some(code) = &self.code {
            value["code"] = json!(code);
        }
        value
    }
}

impl fmt::Display for ToolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

pub type ToolResult = Result<Value, ToolError>;
pub type UnitResult = Result<(), ToolError>;
