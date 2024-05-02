FROM alpine/k8s:1.29.4

ENV NAMESPACES=default,infrastructure

COPY create-awsecr-secret.sh /apps/create-awsecr-secret.sh
RUN chmod u+x /apps/create-awsecr-secret.sh

CMD [ "/bin/ash","-c","/apps/create-awsecr-secret.sh" ]
