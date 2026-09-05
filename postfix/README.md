# Postfix Email-to-Case Relay

This component is the planned replacement for the current AWS Mail Manager
inbound path for `johnkoepp.com`.

It accepts Internet SMTP on TCP port 25, accepts mail only for the address in
`POSTFIX_INCOMING_MAILBOX`, and relays it to the configured Salesforce
Email-to-Case service address without changing the sender or message headers.

The target design is documented in [design.md](design.md). The ordered build,
cutover, rollback, and validation procedure is in
[implementation.md](implementation.md).

## Scope

- Inbound SMTP for `johnkoepp.com` after its existing AWS Mail Manager MX
  record is replaced.
- One explicit recipient mapping:
  `POSTFIX_INCOMING_MAILBOX` to `POSTFIX_DESTINATION_MAILBOX`.
- Basic Postfix queueing, delivery retries while the pod is running, and
  sender/header-preserving delivery to Salesforce Email-to-Case.
- An intentionally ephemeral queue suitable for demonstration only.

## Non-goals

- Replacing or changing existing SES outbound users, SMTP credentials, or
  verified identities.
- General mailbox hosting, IMAP, POP3, or webmail.
- Spam and malware scanning in the initial release.
- TLS for inbound SMTP. Plain SMTP is an explicit initial requirement.

## Operational Prerequisites

Configure the inbound address in `postfix/.env`:

```dotenv
POSTFIX_INCOMING_MAILBOX=sfsupport@johnkoepp.com
```

The deploy script escapes that value for Postfix's regular-expression map, so
it is accepted as one literal address rather than a pattern.

- A stable public IP with a PTR record for `mail.johnkoepp.com`.
- ISP/router TCP/25 forwarding to the Kubernetes host.
- Existing host-managed iptables DNAT/SNAT forwarding to the Envoy Gateway
  LoadBalancer address.
- Outbound TCP/25 access and a public-IP reputation acceptable to receiving
  mail providers.
- DNS authority for MX, A/AAAA, and PTR records.

Do not change the live MX record until the complete pre-cutover validation in
[implementation.md](implementation.md) has passed.

## Demo Queue Behavior

The relay does not use a PVC. Postfix uses the queue created in the container
image, so queued mail is lost if the pod restarts or is rescheduled. This is an
intentional simplification for the demo environment and is not suitable for a
production inbound relay.
