# Implementation Plan

## 1. Preflight

1. Capture the current AWS Mail Manager MX record and rule-set configuration
   for rollback. Confirm that it is the sole inbound service and that SES
   outbound users remain unaffected.
2. Confirm the public IP is static, outbound TCP/25 is permitted, and the ISP
   can serve the PTR record `mail.johnkoepp.com`.
3. Inspect the existing host HTTP/S iptables NAT rules with elevated access.
   Reuse their chain placement and persistence mechanism for SMTP rather than
   introducing a second firewall-management method.
4. Confirm the cluster has the `TCPRoute` CRD version required by Envoy Gateway
   and that `192.168.1.246` is reachable from the Kubernetes host.
5. Confirm there are no other active inbound recipients for
   `johnkoepp.com`; this component intentionally rejects them.

## 2. Host And DNS Preparation

1. Add persistent host firewall rules for TCP/25:
   - DNAT traffic addressed to the host on TCP/25 to `192.168.1.246:25`.
   - Permit the matching forwarded new connection and established return
     traffic.
   - Apply SNAT/MASQUERADE for the forwarded SMTP flow when needed to preserve
     symmetric return routing through the host.
   - Apply logging and source-address connection/rate limits before NAT.
2. Create `mail.johnkoepp.com` A/AAAA and PTR records, but do not change the
   apex MX yet.
3. Do not publish a new SPF, DKIM, or DMARC identity for this forwarding path.
   It preserves the original sender identity and message headers for Salesforce
   Email-to-Case.

## 3. Kubernetes Component

1. Create the component-local contract:
   - `.env` for live values.
   - `.env.sample` containing placeholders only.
   - `scripts/deploy.sh`, `scripts/destroy.sh`, and `scripts/check-deploy.sh`.
   - `manifests/` for namespace, Service, Deployment, ConfigMaps, and
     Gateway route.
   - Require `POSTFIX_INCOMING_MAILBOX` and render it as an escaped, anchored
     Postfix recipient-map expression.
2. Add a custom image that packages pinned Postfix. Build and push it through
   the repository's existing local-registry workflow.
3. Store the recipient mapping and all Postfix configuration in ConfigMaps.
4. Configure Postfix with `mail.johnkoepp.com` hostname, direct-MX delivery,
   the explicit virtual recipient map, bounded queue/message limits, and
   plaintext inbound SMTP. Do not configure a milter, sender canonical map, or
   other mechanism that changes the envelope sender or message headers.
5. Add the TCP listener to `johnkoepp-com-gateway` and a `TCPRoute` that binds
   only to the `smtp` listener and routes to the Postfix Service.

## 4. Validation Before MX Cutover

1. Run the component's manifest preview and deploy checks. Confirm the
   Deployment is Ready and the Gateway and TCPRoute report `Accepted`.
2. From a host outside the LAN, connect to public TCP/25 and verify the SMTP
   banner reaches Postfix through the router, host NAT, Envoy, and TCPRoute.
3. Send a controlled test to the configured `POSTFIX_INCOMING_MAILBOX`. Verify:
   - The destination mailbox receives exactly one message.
   - The original envelope sender, `From`, `Sender`, and `Reply-To` values are
     unchanged.
   - `Message-ID`, `In-Reply-To`, and `References` are unchanged.
   - Any original DKIM signature remains present and unchanged.
   - Salesforce creates or associates the case with the original sender.
4. Send to a different `@johnkoepp.com` local part and verify `550` rejection.
5. Simulate a temporary recipient-MX failure. Verify Postfix queues the
   accepted message, retries delivery, and succeeds after recovery while the
   pod remains running. A pod restart or reschedule intentionally discards the
   container-local queue in this demo design.

## 5. Cutover And Rollback

1. Change the `johnkoepp.com` MX record from the AWS Mail Manager ingress
   endpoint to `mail.johnkoepp.com`.
2. Monitor Postfix queue depth, delivery status, rejected-recipient counts,
   host firewall counters, and external mailbox delivery for at least one DNS
   TTL and a full retry interval.
3. If inbound mail fails or delivery quality is unacceptable, restore the
   captured AWS Mail Manager MX record, leave the Kubernetes component stopped
   or isolated, and investigate using Postfix and firewall logs.
4. Retain the AWS Mail Manager ingress endpoint and rule set until the new
   service has remained stable. Their later removal is optional and does not
   affect SES outbound identities or users.
