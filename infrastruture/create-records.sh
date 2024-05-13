#
# Loop thru both Certificate and HTTPRoute resources looking for items tagged for creation
# of AWS Route53 A Records.  Resources with the following labels are processed.
#
#   koeppster.net/aws_common_name=<hosthost in route53 hosted zone>
#   koeppster.net/aws_status=waiting
#
# After processing the label koeppster.net/aws_status will be change to updated.
# First check if aliases are used
if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
    shopt -s expand_aliases
fi
while true; do
    echo "Checking for Certificate Candiates..."
    CANDIDATES=$(kubectl get certificate -o jsonpath='{range .items[*]}{.metadata.labels.koeppster\.net/aws_common_name}{","}{.metadata.namespace}{","}{.metadata.name}{"\n"}{end}' -A --selector=koeppster.net/aws_status=waiting)
    for CANDIDATE in ${CANDIDATES}; do
        FQDN="${CANDIDATE%%,*}"
        HOSTED_ZONE="${FQDN#*.}"
        HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${HOSTED_ZONE}" --max-items 1 | jq '.HostedZones[0].Id' - | tr -d '"' | cut -d '/' -f3)
        CANDIDATE="${CANDIDATE#*,}"
        NAMESPACE="${CANDIDATE%%,*}"
        CERTIFICATE="${CANDIDATE#*,}"
        echo Will create ${FQDN} in ${HOSTED_ZONE}-${HOSTED_ZONE_ID} for ${CERTIFICATE} in ${NAMESPACE}
        TMPFILE=$(mktemp)
        cat <<EOF > ${TMPFILE}
{
    "Comment": "Updating ${HOSTED_ZONE} A Record for ${FQDN}",
    "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "ResourceRecords": [
                {
                    "Value": "${KUBE_HOST_IP}"
                }
            ],
            "Name" : "${FQDN}",
            "Type": "A",
            "TTL": 300
        }
    }]
}
EOF
        aws route53 change-resource-record-sets --hosted-zone=${HOSTED_ZONE_ID} --change-batch=file://${TMPFILE}
        kubectl label httproute "${CERTIFICATE}" koeppster.net/aws_status=updated -n="${NAMESPACE}" --overwrite
    done
    echo "Checking for HTTPRoute Candiates..."
    CANDIDATES=$(kubectl get httproute -o jsonpath='{range .items[*]}{.metadata.labels.koeppster\.net/aws_common_name}{","}{.metadata.namespace}{","}{.metadata.name}{"\n"}{end}' -A --selector=koeppster.net/aws_status=waiting)
    for CANDIDATE in ${CANDIDATES}; do
        FQDN="${CANDIDATE%%,*}"
        HOSTED_ZONE="${FQDN#*.}"
        HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${HOSTED_ZONE}" --max-items 1 | jq '.HostedZones[0].Id' - | tr -d '"' | cut -d '/' -f3)
        CANDIDATE="${CANDIDATE#*,}"
        NAMESPACE="${CANDIDATE%%,*}"
        CERTIFICATE="${CANDIDATE#*,}"
        echo Will create ${FQDN} in ${HOSTED_ZONE}-${HOSTED_ZONE_ID} for ${CERTIFICATE} in ${NAMESPACE}
        TMPFILE=$(mktemp)
        cat <<EOF > ${TMPFILE}
{
    "Comment": "Updating ${HOSTED_ZONE} A Record for ${FQDN}",
    "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "ResourceRecords": [
                {
                    "Value": "${KUBE_HOST_IP}"
                }
            ],
            "Name" : "${FQDN}",
            "Type": "A",
            "TTL": 300
        }
    }]
}
EOF
        aws route53 change-resource-record-sets --hosted-zone=${HOSTED_ZONE_ID} --change-batch=file://${TMPFILE}
        kubectl label httproute "${CERTIFICATE}" koeppster.net/aws_status=updated -n="${NAMESPACE}" --overwrite
    done
    echo "Waiting for ${RUN_INTERVAL}"
    sleep ${RUN_INTERVAL}
done