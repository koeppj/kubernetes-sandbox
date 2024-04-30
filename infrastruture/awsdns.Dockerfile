FROM alpine/k8s:1.29.4

ENV RUN_INTERVAL=30

COPY create-records.sh /apps/create-records.sh
RUN chmod u+x /apps/create-records.sh

CMD [ "/bin/ash","-c","/apps/create-records.sh" ]
