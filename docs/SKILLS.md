# Reusable AI skills, custom agents and the agent marketplace

Amer → **Skills and marketplace**, or `/skill` in a chat to run one on that chat's recent messages.

- **Skill:** a reusable instruction with inputs, written as `{{name}}`. For example, "Draft an RFP clause about {{topic}}. Constraints: {{constraints}}." Running it asks for each input.
- **Custom agent:** a standing persona whose instructions are the system prompt ("You are our DWDM capacity planner…"). Running it asks for your request.
- **Lifecycle:** private (author only) → **Submit** → an administrator **approves** (with an optional note) or **rejects** (a reason is required) → approved items appear in the organisation's **marketplace** (same tenant only) → people **install** them. Install counts are shown. Editing an approved item creates a new version and sends it back for review, off the marketplace until approved again.
- **Safety:** instructions that try to make the AI ignore its rules or the policy check are refused at save time. Every run goes through Guardian, redaction and the chat's sensitivity label (Confidential and Restricted are blocked) like any AI request. Results are private until you **Share in chat**.
- Tested on the real stack: `tests/skills_test.py`, 13/13. The local stack has no AI provider key, so the model step itself answered "key not set"; routing, policy and permissions were all exercised.

## Open gaps
- Skill runs use the AI service path; the encrypted enclave path isn't wired for skills yet (`GET /v1/skills/{id}/prepare` is there for it).
- Skills can't call tools (files, calendar, workflows) yet: text in, text out.
- No cross-organisation marketplace (by design for now).
