UPDATE agent_workspace_signals
SET source_session_id = COALESCE(
        source_session_id,
        (SELECT member.source_session_id
         FROM agent_workspace_members member
         WHERE member.workspace_id = agent_workspace_signals.workspace_id
           AND member.member_id = agent_workspace_signals.member_id)
    ),
    source_agent_id = COALESCE(
        source_agent_id,
        (SELECT member.source_agent_id
         FROM agent_workspace_members member
         WHERE member.workspace_id = agent_workspace_signals.workspace_id
           AND member.member_id = agent_workspace_signals.member_id)
    ),
    delivery_runtime_session_id = COALESCE(
        delivery_runtime_session_id,
        (SELECT COALESCE(member.runtime_session_id, member.workspace_id)
         FROM agent_workspace_members member
         WHERE member.workspace_id = agent_workspace_signals.workspace_id
           AND member.member_id = agent_workspace_signals.member_id)
    ),
    delivery_project_dir = COALESCE(
        delivery_project_dir,
        (SELECT COALESCE(workspace.project_dir, workspace.context_root)
         FROM agent_workspaces workspace
         WHERE workspace.workspace_id = agent_workspace_signals.workspace_id)
    )
WHERE origin_kind = 'native';
