# Target Design

## Purpose

Receive mail for the address configured as `POSTFIX_INCOMING_MAILBOX` and
deliver it to the configured Salesforce Email-to-Case service address. The
service preserves the original
SMTP envelope sender and all original message headers, including `From`,
`Message-ID`, `In-Reply-To`, and `References`. The component replaces the
existing AWS Mail Manager inbound rule set only; SES outbound users and
identities are independent and remain in place.

## Traffic Flow

```text
Internet SMTP client
  -> ISP/router public TCP/25 forwarding
  -> Kubernetes host iptables DNAT/SNAT
  -> Envoy Gateway LoadBalancer 192.168.1.246:25
  -> johnkoepp-com-gateway TCP listener
  -> TCPRoute
  -> postfix Service
  -> Postfix Deployment
  -> recipient MX server over outbound TCP/25
```

The host continues to use its existing iptables forwarding pattern rather than
adding HAProxy. DNAT routes TCP/25 to Envoy. A matching `FORWARD` rule permits
the connection, and stateful return traffic is allowed. The forwarding flow
uses SNAT/MASQUERADE when required to ensure Envoy responses return through the
host and therefore match the router's connection-tracking state.

## Kubernetes Design

The public `johnkoepp-com-gateway` receives a dedicated TCP listener named
`smtp` on port 25. A `gateway.networking.k8s.io/v1alpha2` `TCPRoute` attaches
to that listener and forwards to a cluster-internal `postfix` Service on port
25. The existing HTTP and HTTPS listeners remain unchanged.

The component runs as a one-replica Deployment in a `postfix` namespace. This
is a basic demo relay, so it uses the queue created in the container image and
does not mount persistent storage. Postfix can queue and retry mail while the
pod remains running, but queued mail is lost if the pod restarts or is
rescheduled. This tradeoff is intentional and makes the demo independent of
NFS ownership and PVC behavior; it is not a production reliability design.

The pod contains Postfix for SMTP acceptance, queueing, recipient validation,
and direct-MX delivery. The image pins its Postfix version. The pod must not
become Ready unless the recipient map and Postfix configuration are available.

## Recipient And Sender Policy

Postfix owns `johnkoepp.com` only for this inbound role and accepts exactly one
virtual alias:

```text
POSTFIX_INCOMING_MAILBOX -> configured destination mailbox
```

`POSTFIX_INCOMING_MAILBOX` is a required component-local `.env` setting. The
deploy script quotes it for the Postfix regexp table, so changing the setting
changes the one accepted literal address without widening the allowlist.

All other local parts at `johnkoepp.com` receive an SMTP `550` response. This
recipient gate is mandatory; it prevents the service from operating as an open
relay.

For an accepted message, Postfix changes only the envelope recipient to the
configured Salesforce Email-to-Case service address. It must preserve:

- SMTP `MAIL FROM`.
- `From`, `Sender`, and `Reply-To` headers.
- `Message-ID`, `In-Reply-To`, and `References` headers used by Salesforce
  Email-to-Case threading.
- Existing DKIM signatures and all other message headers.

Postfix does not rewrite the sender, add a replacement `Sender` header, remove
DKIM signatures, or apply a new DKIM signature. Salesforce uses the original
`From` address to identify the sender and associates replies using the original
threading headers. Postfix uses `mail.johnkoepp.com` as its hostname and HELO
identity, leaves `relayhost` empty, and delivers directly to destination MX
records.

## Security And Reliability

Inbound SMTP deliberately remains plaintext: Postfix does not offer or require
STARTTLS in the first release. SMTP transport metadata and message contents may
therefore be visible to sending networks that do not independently encrypt the
connection.

The initial abuse controls are limited to:

- Explicit recipient allowlisting.
- SMTP syntax and DNS sanity checks.
- Message-size, connection, and process limits.
- Host-level source connection/rate limits using iptables.

Spam scoring, malware scanning, quarantine handling, and inbound TLS are out
of scope for the first release. They can be added without changing the TCP
entrypoint or recipient-map model.

Salesforce's routing address must accept the expected original sender
addresses. Do not restrict its `Accept Email From` configuration to a local
relay address, because this component intentionally preserves external sender
addresses.

## DNS And Network Records

At cutover, publish the following for the existing public IP:

```text
johnkoepp.com.                 MX 10 mail.johnkoepp.com.
mail.johnkoepp.com.            A    <public-ip>
<public-ip PTR>                     mail.johnkoepp.com.
```

The previous AWS Mail Manager MX endpoint must be retained as the rollback
value until the service has completed external delivery validation.
