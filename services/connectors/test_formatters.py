from formatters import render
def test_alertmanager_and_jira():
    a = render("alertmanager", "NOC", {"alerts": [{"status": "firing", "labels": {"alertname": "OchOsnrLow", "severity": "critical", "instance": "AUH-DXB-1"}, "annotations": {"summary": "OSNR 14 dB"}},
                                                  {"status": "resolved", "labels": {"alertname": "FanFail"}}]}, {})
    assert a.startswith("[NOC] 🚨 CRITICAL OchOsnrLow · AUH-DXB-1\nOSNR 14 dB") and "✅ RESOLVED FanFail" in a
    j = render("jira", "Jira", {"webhookEvent": "jira:issue_updated", "issue": {"key": "OPT-12", "fields": {"summary": "Replace amplifier", "status": {"name": "In Progress"}, "priority": {"name": "High"}}}}, {})
    assert j == "[Jira] 🎫 OPT-12 issue updated: Replace amplifier\nStatus In Progress · priority High · assignee unassigned"
def test_bad_payload_falls_back():
    assert render("github", "GH", {"weird": 1}, {"X-GitHub-Event": "ping"}).startswith("[GH] GitHub ping")
