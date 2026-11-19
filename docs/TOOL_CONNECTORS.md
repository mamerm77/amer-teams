# Tool connectors

Chat menu → **Connectors** → **Add connector**: GitHub, GitLab, Jira, Prometheus Alertmanager, Grafana alerts, ServiceNow, Jenkins, or any tool that can post JSON with a `text` field.

1. A chat host adds a connector and gets a **secret webhook URL** (`https://<server>/hooks/<id>/<secret>`). It's shown once and stored hashed. The app invites the **Connectors** account into the chat.
2. The Connectors account (`services/connectors`) is an ordinary end-to-end encrypted Matrix member, visible in the member list. It joins only chats that have a connector, and refuses other invites.
3. When the tool calls the URL, the service checks the secret with the server, formats the event and posts it **encrypted** as a notice: for example "[GitHub] ⬆️ moh pushed 2 commit(s) to … main" with the commit lines, "[NOC] 🚨 CRITICAL OchOsnrLow · AUH-DXB-1", or "[Jira] 🎫 OPT-12 issue updated…". Logs carry no content.
4. **Remove** stops the URL working at once. The chat lists its connectors with use counts.

Tested on the real stack: `tests/connectors_test.py`, 7/7. A real encrypted client decrypts the posted message, and a wrong secret, a chat without a connector and a removed connector are all refused. Formatters are tested in `services/connectors/test_formatters.py`.

## Open gaps
- Incoming only. Outgoing actions (create a Jira ticket from a task, open a ServiceNow incident from Operator mode) need each tool's API credentials, and aren't built.
- No signature check of the tool's own webhook signing (for example GitHub's `X-Hub-Signature-256`); the secret in the URL is the check.
