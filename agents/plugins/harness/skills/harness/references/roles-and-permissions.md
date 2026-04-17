# Roles and permissions

## Permission matrix

| Action | Leader | Observer | Worker | Reviewer | Improver |
|--------|--------|----------|--------|----------|----------|
| End session | yes | no | no | no | no |
| Join agent | yes | no | no | no | no |
| Remove agent | yes | no | no | no | no |
| Assign role | yes | no | no | no | no |
| Transfer leader | yes | yes | no | no | no |
| Create task | yes | yes | yes | yes | yes |
| Assign task | yes | no | no | yes | yes |
| Update task status | yes | no | yes | yes | yes |
| Observe session | yes | yes | yes | yes | yes |
| View status | yes | yes | yes | yes | yes |

## Role descriptions

**Leader** - Full control over the session. Starts the session, manages agents, assigns work, ends the session. There is exactly one leader at a time. Leadership can be transferred.

**Observer** - Watches session activity through the observe pipeline. Can create tasks from observations (detected issues become work items). Can initiate leader transfer if the leader is unresponsive.

**Worker** - Executes assigned tasks. Can create new tasks (discovered sub-work) and update status on their own tasks. Cannot assign tasks to others.

**Reviewer** - Reviews completed work. Can assign tasks back to workers and update task status. Cannot manage agents or end the session.

**Improver** - Like reviewer but focused on improvement tasks. Can assign tasks and update status. Typically used for refactoring or quality improvement work.

## Leader transfer

Transfer is initiated by:
- The current leader voluntarily (`harness session transfer-leader`)
- An observer when the leader appears unresponsive

The transfer updates the role of both agents atomically and logs the transition.

## Recovery

If a session becomes leaderless:

```
harness session recover-leader <session-id>
```

This starts a managed TUI leader interface to recover the session.
