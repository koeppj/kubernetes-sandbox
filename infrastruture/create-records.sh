# First check if aliases are used
if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
    shopt -s expand_aliases
fi
while true; do
    CANDIDATES=$(kubectl get certificate -o jsonpath='{range .items[*]}{.metadata.labels.aws_common_name}{","}{.metadata.namespace}{","}{.metadata.name}{"\n"}{end}' --selector=aws_status=waiting)
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
    kubectl label certificate "${CERTIFICATE}" aws_status=updated -n="${NAMESPACE}" --overwrite
    done
    echo "Waiting for ${RUN_INTERVAL}"
    sleep ${RUN_INTERVAL}
done
