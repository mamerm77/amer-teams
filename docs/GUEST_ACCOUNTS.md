# Guest accounts

For external people who work with you for weeks, not just one meeting (one meeting: GUESTS.md).

- An administrator creates **guest.username** with a name, work email (only its domain is kept), sponsor (the administrator) and an expiry of 7 to 180 days. The account is a real Matrix account, so chats with the guest stay end-to-end encrypted. The guest gets a one-time password.
- **Enforced by the server** (Synapse policy module, `deploy/synapse-modules/amer_federation.py`): a guest cannot create rooms, cannot invite anyone, and can join only rooms they were invited to (even public ones are refused). Inside those rooms, they take part normally.
- **Expiry:** checked every ten minutes and whenever the list is opened; at expiry the account is deactivated. **End now** does it at once.
- Tested on the real stack: `tests/guest_accounts_test.py`, 10/10.

## Open gaps
- Only administrators can create guests; sponsor-by-any-employee with approval isn't built.
- The one-time password is shown to the administrator, not emailed (no mail connector yet).
