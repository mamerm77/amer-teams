# Plain-language workflows

Phase 3, Workflows and integrations (docs/PHASE3_REQUIREMENTS.docx). Benchmarks: Teams Workflows, Slack Workflow
Builder, Google Workspace Studio.

## Using it
Amer tab → **Workflows** → **New workflow**:
1. Describe it ("when someone posts a quote in RFP, ask Sara to approve and post the result in RFP log") and tap
   **Draft with Amer**, or **Start from a template**.
2. Amer returns the definition and the **assumptions** it made (e.g. who approves). The flow is shown as steps, and
   any validation errors are listed.
3. **Dry run** with sample data. It sends nothing and shows what each step would do and which branch it takes.
4. **Save** creates version N, and **Switch on** starts listening. Editing saves version N+1. Runs already in
   progress keep the version they started with.
5. Each workflow lists its runs with every step's status and any error. **Run now** runs it by hand.

## Definition
JSON, versioned, at most 50 steps. Format as in the spec:
- **Triggers:** `message` (chat, keywords, has_file, from), `schedule` (5-field cron, device local time), `manual`.
- **Steps:**
  - `post` (chat, text with `{{s1.field}}`)
  - `ask_form` (person, fields; gives `$sN.<field>`)
  - `approval` (people, timeout_h; gives `$sN.decision`, `$sN.by`)
  - `condition` (`$s1.amount > 500000`, `==`, `!=`, `<`, `<=`, `>=`, `contains`; then/else)
  - `wait` (minutes)
  - `run_agent` (prompt; gives `$sN.answer`)
  - `http` (https URL)
- Steps run in order unless a condition branches; `"next": "end"` stops.
- **Refused for now:** `create_task` and `call_connector` arrive with task boards and connectors. Approver
  *roles* (`role:finance_manager`) are refused because roles do not exist yet; name the people.

**Validation**, on the server, at save, enable and run:
- known types and fields; unique ids; every step reachable;
- no cycle without a wait;
- the owner is a member of every chat the workflow names. This is checked again before each run, so a workflow
  cannot post into a chat its owner has left.

## Where it runs (encryption rule)
- **The owner's device** runs the runner (`app/lib/services/workflow_runner.dart`). It reads message triggers
  (decrypted on the device) and sends posts, forms and approvals as the owner, encrypted, with the owner's own
  rights. It runs only while the app is open on one of the owner's devices. Each run belongs to the device that
  started it, so two devices never both run it.
- **Forms and approvals** are cards in the chat. Only the people asked see **Fill in** or **Approve / Reject**.
  The answer is an encrypted room event (`com.amerteams.workflow.response`), accepted only from those people.
- **Waits and pending approvals** are kept in a file on the device and resume after a restart. An approval past
  its `timeout_h` fails the run (timed out). A run is capped at 30 days.
- **The server** (`services/orchestrator/app/workflows.py`, tables `workflows`, `workflow_runs`,
  `workflow_hosts`):
  - stores versions;
  - keeps run records: trigger type, chat, event id, sender and device, plus each step's status, attempt, error
    and the *names* of the fields it produced. Never message text or form values;
  - counts runs (1,000 a day per workflow);
  - makes runs idempotent (`Idempotency-Key` = triggering event id);
  - executes `http` steps only to hosts an administrator approved (`/v1/admin/workflow-hosts`).
- **Every step** is written to the audit log and streamed to Agent Ops (project `wf-<run id>`).
- **Retries:** 3, after 1 s, 4 s and 16 s with jitter. 4xx errors are not retried. After the last failure the run
  fails and the step and error show on the workflow's runs.

## Gaps against the requirement (open)
- Webhook, form-submitted, alarm and calendar triggers are not built (message, schedule and manual are).
- The flow can be edited as JSON, not by dragging boxes.
- No enclave: runs need one of the owner's devices online.
- Failure notifications show in the Workflows screen, not as a push notification yet.

## Tests
- `services/orchestrator/tests/test_workflows.py` (12), including the spec's four acceptance tests:
  - a cycle without a wait is rejected at save;
  - a dry run sends nothing;
  - a workflow cannot use a chat its owner has left;
  - a new version does not change runs in progress.
- The PostgreSQL store was also run against a real database.
- `app/test/workflow_engine_test.dart`: conditions, templates, branching, trigger matching and cron, with the
  same cases as the server.
- In-use (CI): create from a template, a message in the chat triggers an approval card, tapping Approve
  continues the run, and the workflow posts the result.
