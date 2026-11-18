# Phone network (SIP / PSTN)

Amer Teams users can call ordinary phone numbers, and your company numbers (DIDs) can ring into Amer Teams.

## Security
A normal phone cannot take part in end-to-end encryption. Phone calls are therefore a **separate call type** in their own room and are never mixed into an end-to-end encrypted meeting. The app shows *"Encrypted to the phone network (TLS + SRTP), not end-to-end"*.
- Every trunk is created with **SIP over TLS** and **SRTP required**; carriers that cannot do this are refused.
- Off by default. An admin enables it and sets which country prefixes may be dialled (e.g. `+971`).
- Premium-rate and satellite ranges are always blocked. Every call and change is audited with the number masked.

## Set up
1. Get a SIP trunk from your carrier (e.g. a business SIP trunk with TLS/SRTP). You need: SIP address (host:5061), your DID numbers, username/password, and the carrier's signalling IP ranges.
2. Put a TLS certificate for your SIP host in `deploy/sip-certs/sip.crt` and `sip.key`.
3. Start the gateway: `docker compose --profile phone up -d livekit-sip`. Open UDP 10000–20000 and TCP 5061 to the carrier's IP ranges only.
4. As admin (Users screen or API):
   - `POST /api/v1/phone/trunks` with the carrier details: creates outbound + inbound trunks and the inbound routing rule.
   - `PUT /api/v1/phone/policy` `{"enabled": true, "allowed_prefixes": ["+971"]}`.
5. In the app: **Phone** → enter a number in international format → Call.

## Kubernetes
`deploy/k8s/45-sip.yaml` runs two gateway nodes (host networking, one per node) sharing state through Redis Sentinel.
