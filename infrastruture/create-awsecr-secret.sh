#
# Update the registry token secret for the private ECR registry
#
# First check if aliases are used
if [ -f ~/.bash_aliases ]; then
    shopt -s expand_aliases
    source ~/.bash_aliases
fi
echo "========= START AWS ECR Secret Update ============"
#
# Make sure to be able to process a comma seperated value as an array
IFS=','
#
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
AWS_ECR_TOKEN=$(aws ecr get-login --registry-ids ${AWS_ACCOUNT_ID} | cut -d' ' -f6)
for NAMESPACE in ${NAMESPACES}; do
    kubectl delete secret --ignore-not-found aws-ecr-secret
    kubectl create secret docker-registry aws-ecr-secret \
        --docker-server=https://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com\ \
        --docker-username=AWS \
        --docker-password="${AWS_ECR_TOKEN}" \
        --docker-email=monitor@koeppster.net
    kubectl patch serviceaccount default -n $NAMESPACE -p '{"imagePullSecrets":[{"name":"aws-ecr-secret"}]}'
    echo "Updated namespace ${NAMESPACE}"
done
echo "========== END AWS ECR Secret Update ============="
