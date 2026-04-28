use agent_client_protocol::schema::{
    CreateTerminalRequest, RequestPermissionRequest, ToolCallUpdate, ToolCallUpdateFields,
    WriteTextFileRequest,
};
use serde_json::json;

use crate::agents::acp::permission::standard_permission_options;

pub(super) fn write_permission_request(request: &WriteTextFileRequest) -> RequestPermissionRequest {
    let tool_call = ToolCallUpdate::new(
        format!("fs.write_text_file:{}", request.path.display()),
        ToolCallUpdateFields::new()
            .title("Write file")
            .raw_input(json!({
                "kind": "fs.write_text_file",
                "path": request.path.display().to_string(),
                "contentBytes": request.content.len(),
            })),
    );
    RequestPermissionRequest::new(
        request.session_id.to_string(),
        tool_call,
        standard_permission_options(),
    )
}

pub(super) fn terminal_permission_request(
    request: &CreateTerminalRequest,
) -> RequestPermissionRequest {
    let tool_call = ToolCallUpdate::new(
        format!("terminal.create:{}", request.command),
        ToolCallUpdateFields::new()
            .title("Create terminal")
            .raw_input(json!({
                "kind": "terminal.create",
                "command": &request.command,
                "args": &request.args,
                "cwd": &request.cwd,
            })),
    );
    RequestPermissionRequest::new(
        request.session_id.to_string(),
        tool_call,
        standard_permission_options(),
    )
}
